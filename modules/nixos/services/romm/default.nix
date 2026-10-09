# First-party RomM app: a ROM library manager with a built-in emulator. Upstream serves the frontend,
# the ROM downloads and the emulator's cross-origin headers from its own nginx virtual host, so ingress
# routes to that vhost and the API keeps a separate socket behind it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  app = cfg.apps.romm;
  serviceCfg = cfg.services.romm;
  oidcCfg = cfg.auth.oidc;
  rommCfg = config.services.romm;

  federated = serviceCfg.access.model == "oidc";
  publicIsTls = lib.hasPrefix "https://" serviceCfg.publicUrl;

  units = [
    "romm"
    "romm-worker"
    "romm-scheduler"
  ]
  ++ lib.optional rommCfg.watcher.enable "romm-watcher";

  yamlFormat = pkgs.formats.yaml { };
  rendered = lib.generators.toYAML { } app.settings;
  configFile = pkgs.writeText "romm-config.yml" rendered;

  declarative = app.settings != { };
  # A config carrying a generated password cannot sit in the world-readable store, so it renders at boot.
  secretBearing = lib.any (placeholder: lib.hasInfix placeholder rendered) (lib.attrValues cfg.runtimePlaceholder);
  configPath = if secretBearing then cfg.runtimeTemplates."romm-config.yml".path else "${configFile}";

  turn = cfg.apps.coturn;
  turnLogin = "romm";

  # RomM has two roles, admin and everyone else, so EDITOR and VIEWER are interchangeable seats for
  # naming a group. A group with no seat is refused at login even where the provider allows it, and
  # the registry's "empty means unrestricted" is RomM's `*` wildcard.
  roleSeats = lib.filter (group: group != cfg.groups.admin) serviceCfg.access.allowedGroups;
  roleEnv =
    if serviceCfg.access.allowedGroups == [ ] then
      {
        OIDC_ROLE_ADMIN = cfg.groups.admin;
        OIDC_ROLE_VIEWER = "*";
      }
    else
      lib.optionalAttrs (lib.elem cfg.groups.admin serviceCfg.access.allowedGroups) {
        OIDC_ROLE_ADMIN = cfg.groups.admin;
      }
      // lib.optionalAttrs (roleSeats != [ ]) { OIDC_ROLE_EDITOR = lib.head roleSeats; }
      // lib.optionalAttrs (lib.length roleSeats > 1) { OIDC_ROLE_VIEWER = lib.elemAt roleSeats 1; };
in
{
  options.selfhost.apps.romm = {
    enable = lib.mkEnableOption "the first-party RomM app (ROM library manager)";

    settings = lib.mkOption {
      inherit (yamlFormat) type;
      default = { };
      example = {
        system.platforms.megadrive = "genesis";
        exclude.roms.multi_file.names = [ "artwork" ];
      };
      description = "RomM's `config.yml`: platform bindings, scan exclusions, EmulatorJS. Linked in rather than written, so RomM reports it read-only and its own config editor refuses to save. Empty leaves the file to RomM. Keys are upstream's, see <https://github.com/rommapp/romm/blob/master/examples/config.example.yml>.";
    };

    netplay.enable = lib.mkOption {
      type = lib.types.bool;
      default = turn.enable;
      defaultText = lib.literalExpression "config.selfhost.apps.coturn.enable";
      description = "Point EmulatorJS netplay at the coturn app, with a generated TURN credential and a STUN/TURN pair per advertised address.";
    };
  };

  config = lib.mkIf app.enable {
    warnings =
      lib.optional (federated && lib.length roleSeats > 2)
        "selfhost.services.romm.access.allowedGroups names ${toString (lib.length roleSeats)} non-admin groups, but RomM maps only two, so ${lib.concatStringsSep ", " (lib.drop 2 roleSeats)} is refused at login.";

    assertions = [
      {
        assertion = app.netplay.enable -> turn.enable;
        message = "selfhost.apps.romm.netplay.enable needs selfhost.apps.coturn.enable: the credential and the relay addresses come from there.";
      }
      {
        assertion = app.netplay.enable -> turn.advertisedAddresses != [ ];
        message = "selfhost.apps.romm.netplay.enable needs selfhost.apps.coturn.advertisedAddresses: a browser cannot reach a relay nothing advertises.";
      }
    ];

    selfhost = {
      services.romm = {
        displayName = lib.mkDefault "RomM";
        meta.homepage = lib.mkDefault "https://romm.app";
        meta.description = lib.mkDefault "ROM Manager";
        meta.category = lib.mkDefault "media";
        port = lib.mkDefault 8095;
        healthcheck.path = "/api/heartbeat";
        # The worker, the scheduler and the watcher read the same library, so the automount guards and
        # the failure notifications have to cover them too.
        systemdServices = units;
        # nginx serves the ROM downloads straight off the library, so it needs the share as well.
        storage.users = [ rommCfg.user ] ++ lib.optional rommCfg.nginx.enable config.services.nginx.user;
        # RomM keeps its local accounts either way, so it federates only where a provider exists.
        access.model = lib.mkDefault (if oidcCfg.active then "oidc" else "native");
        access.oidc = {
          callbackURLs = lib.mkDefault [ "${serviceCfg.publicUrl}/api/oauth/openid" ];
          systemd.dependentServices = [ "romm" ];
        };
      };

      internal.listeningPorts = [
        {
          name = "romm/api";
          host = rommCfg.listenAddress;
          inherit (rommCfg) port;
        }
      ];

      # RomM reads the client credentials from the environment: the `_FILE` convention its container
      # documents comes from that image's entrypoint, which the package does not ship.
      runtimeTemplates."romm.env" = lib.mkIf federated {
        content = ''
          OIDC_CLIENT_ID=${cfg.oidcPlaceholder.romm.id}
          OIDC_CLIENT_SECRET=${cfg.oidcPlaceholder.romm.secret}
        '';
        restartUnits = [ "romm.service" ];
      };

      runtimeTemplates."romm-config.yml" = lib.mkIf secretBearing {
        content = rendered;
        owner = rommCfg.user;
        restartUnits = map (unit: "${unit}.service") units;
      };

      apps.coturn.logins = lib.mkIf app.netplay.enable [ turnLogin ];

      apps.romm.settings = lib.mkIf app.netplay.enable {
        emulatorjs.netplay = {
          enabled = true;
          ice_servers =
            let
              port = toString config.services.coturn.listening-port;
            in
            lib.concatMap (address: [
              { urls = "stun:${address}:${port}"; }
              {
                urls = "turn:${address}:${port}?transport=udp";
                username = turnLogin;
                credential = turn.credential.${turnLogin}.placeholder;
              }
            ]) turn.advertisedAddresses;
        };
      };
    };

    services.romm = {
      enable = true;
      nginx.virtualHost = lib.mkDefault serviceCfg.publicHost;
      extraEnvironment = {
        # The vhost is plain HTTP behind the gateway, so upstream would derive both of these wrong from it.
        ROMM_BASE_URL = lib.mkDefault serviceCfg.publicUrl;
        ROMM_SESSION_SECURE_COOKIE = lib.mkDefault (lib.boolToString publicIsTls);
      }
      // lib.optionalAttrs federated (
        {
          OIDC_ENABLED = "true";
          OIDC_PROVIDER = oidcCfg.provider.displayName;
          OIDC_SERVER_APPLICATION_URL = oidcCfg.provider.issuerUrl;
          OIDC_REDIRECT_URI = builtins.head serviceCfg.access.oidc.callbackURLs;
          OIDC_CLAIM_ROLES = lib.mkDefault "groups";
          # The provider's roles make the first admin, so the wizard is an unauthenticated way to make one.
          DISABLE_SETUP_WIZARD = lib.mkDefault "true";
        }
        // lib.mapAttrs (_: lib.mkDefault) roleEnv
      );
    };

    # Upstream fixes the path at `/config/config.yml`.
    systemd.tmpfiles.settings = lib.mkIf declarative {
      "20-romm-config"."${rommCfg.dataDir}/config/config.yml"."L+".argument = configPath;
    };

    systemd.services = lib.mkMerge [
      # Left off `services.romm.environmentFile` so the consumer keeps it for its own credentials:
      # systemd concatenates EnvironmentFile across definitions.
      (lib.mkIf federated {
        romm.serviceConfig.EnvironmentFile = [ cfg.runtimeTemplates."romm.env".path ];
      })
      # Every unit reads the config: the API serves it, the worker scans with it. The rendered path
      # carries its own triggers through `restartUnits`.
      (lib.mkIf (declarative && !secretBearing) (
        lib.genAttrs units (_: {
          restartTriggers = [ configFile ];
        })
      ))
    ];

    # Default rather than fixed: a consumer fronting RomM with nginx itself replaces this wholesale.
    # The gateway owns :80, so the vhost binds the registered socket instead.
    services.nginx.virtualHosts.${rommCfg.nginx.virtualHost}.listen = lib.mkDefault [
      {
        addr = serviceCfg.host;
        inherit (serviceCfg) port;
      }
    ];
  };
}
