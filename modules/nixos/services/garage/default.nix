# First-party Garage app: S3-compatible object storage. `native` access: clients authenticate with
# S3 request signatures, which no gateway can stand in for.
#
# Deliberately has no per-user surface. Object storage is addressed by bucket and key, not by person,
# and a single-node deployment has one of each per consumer.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.garage;
  serviceCfg = config.selfhost.services.garage;

  rpcPort = 3901;

  configFile = pkgs.writeText "garage-configure.json" (
    builtins.toJSON {
      inherit (app) buckets capacity;
      keyEnvFiles = lib.listToAttrs (
        map (b: lib.nameValuePair b config.selfhost.runtimeTemplates."garage-${b}.env".path) app.buckets
      );
    }
  );

  garage-configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "garage-configure";
    runtimeInputs = [ pkgs.coreutils ];
    script = ./configure.nu;
  };
in
{
  options.selfhost.apps.garage = {
    enable = lib.mkEnableOption "the first-party Garage app (S3-compatible object storage)";

    buckets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Buckets to provision. Each also gets an access key of the same name, granted read, write and
        owner on it, whose credentials are generated as runtime secrets and rendered to
        `selfhost.runtimeTemplates."garage-<name>.env"` for the consumer to read.
      '';
    };

    capacity = lib.mkOption {
      type = lib.types.str;
      default = "100G";
      description = "Capacity this node advertises in the cluster layout. A single-node deployment needs it only for the layout to be valid.";
    };
  };

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost.services.garage = {
      displayName = lib.mkDefault "Garage";
      meta.homepage = lib.mkDefault "https://garagehq.deuxfleurs.fr";
      meta.description = lib.mkDefault "S3-compatible object storage";
      port = lib.mkDefault 3900;
      subdomain = lib.mkDefault "s3";
      access.model = "native"; # S3 request signatures
      healthcheck.probeModule = "http_any"; # unsigned requests are refused, which still proves it is up
      integrations.homepage.enable = false; # a storage endpoint, not a destination
    };

    selfhost.internal.listeningPorts = [
      {
        host = "127.0.0.1";
        port = rpcPort;
      }
    ];

    # Garage key IDs are "GK" followed by 24 hex characters, so the id is generated as 12 bytes and
    # prefixed here rather than used raw.
    selfhost.runtimeSecrets =
      lib.listToAttrs (
        lib.concatMap (b: [
          (lib.nameValuePair "garage-key-id-${b}" {
            bytes = 12;
            generateOnce = config.services.garage.settings.metadata_dir;
            restartUnits = [ "garage-configure.service" ];
          })
          (lib.nameValuePair "garage-key-secret-${b}" {
            bytes = 32;
            generateOnce = config.services.garage.settings.metadata_dir;
            restartUnits = [ "garage-configure.service" ];
          })
        ]) app.buckets
      )
      // {
        garage-rpc-secret = {
          bytes = 32;
          restartUnits = [ "garage.service" ];
        };
      };

    selfhost.runtimeTemplates =
      lib.listToAttrs (
        map (
          b:
          lib.nameValuePair "garage-${b}.env" {
            content = ''
              AWS_ACCESS_KEY_ID=GK${config.selfhost.runtimePlaceholder."garage-key-id-${b}"}
              AWS_SECRET_ACCESS_KEY=${config.selfhost.runtimePlaceholder."garage-key-secret-${b}"}
            '';
            restartUnits = [ "garage-configure.service" ];
          }
        ) app.buckets
      )
      // {
        "garage-rpc.env" = {
          content = "GARAGE_RPC_SECRET=${config.selfhost.runtimePlaceholder.garage-rpc-secret}\n";
          restartUnits = [ "garage.service" ];
        };
      };

    services.garage = {
      enable = true;
      package = lib.mkDefault pkgs.garage;
      environmentFile = config.selfhost.runtimeTemplates."garage-rpc.env".path;
      settings = {
        db_engine = lib.mkDefault "sqlite";
        replication_factor = lib.mkDefault 1;
        rpc_bind_addr = "127.0.0.1:${toString rpcPort}";
        rpc_public_addr = "127.0.0.1:${toString rpcPort}";
        s3_api = {
          s3_region = lib.mkDefault "garage";
          api_bind_addr = "127.0.0.1:${toString serviceCfg.port}";
          root_domain = lib.mkDefault ".s3.garage";
        };
      };
    };

    systemd.services.garage-configure = {
      description = "Provision Garage layout, buckets and keys";
      wantedBy = [ "garage.service" ];
      after = [ "garage.service" ];
      requires = [ "garage.service" ];
      partOf = [ "garage.service" ];
      restartTriggers = [ ./configure.nu ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        Restart = "on-failure";
        RestartSec = 10;
        UMask = "0077";
        # No filesystem sandbox: it shells out to the garage CLI, which reads state upstream owns.
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        # The module ships a `garage` wrapper that sources this, but a unit PATH bypasses it: without
        # the RPC secret the CLI cannot reach the node it is configuring.
        EnvironmentFile = config.services.garage.environmentFile;
      };
      environment.GARAGE_PROVISION_FILE = configFile;
      path = [ config.services.garage.package ];
      script = lib.getExe garage-configure;
    };
  };
}
