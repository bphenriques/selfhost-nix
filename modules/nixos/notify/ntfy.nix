# Runs the ntfy-sh server. Publishers and topic visibility are declared here and reconciled by ntfy
# itself; readers are runtime state that ntfy-manage owns.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  serviceCfg = cfg.services.ntfy;
  inherit (cfg.notify) topics;

  secretsDir = "/var/lib/homelab-secrets";
  tokenDir = "${secretsDir}/notify-publishers";
  # Not server.yml: that file is a world-readable store path, and these lines carry password hashes and
  # live tokens. systemd reads EnvironmentFile as root before dropping to the service's DynamicUser.
  authEnvFile = "${secretsDir}/notify-auth.env";

  # A failure topic that differs from the summary one is a second grant, not a replacement.
  publisherTopics =
    p: lib.unique (lib.filter (t: t != null) [ p.integrations.notify.topic p.integrations.notify.failureTopic ]);

  notifyServices = lib.filterAttrs (_: s: s.integrations.notify.enable) cfg.services;
  notifyTasks = lib.filterAttrs (_: t: t.integrations.notify.enable) cfg.tasks;
  localPublishers = lib.mapAttrs (_: p: {
    topics = publisherTopics p;
    inherit (p.integrations.notify) tokenFile;
  }) (notifyServices // notifyTasks);

  remotePublishers = lib.mapAttrs (_: r: {
    topics = [ r.topic ];
    inherit (r) tokenFile;
  }) cfg.notify.ntfy.remotePublishers;

  allPublishers = localPublishers // remotePublishers;
  shadowedPublishers = lib.intersectLists (lib.attrNames cfg.notify.ntfy.remotePublishers) (
    lib.attrNames localPublishers
  );

  configFile = pkgs.writeText "ntfy-manage-config.json" (
    builtins.toJSON {
      adminPasswordFile = cfg.runtimeSecrets.ntfy-admin-password.path;
      publishers = allPublishers;
      topics = lib.mapAttrs (_: t: { inherit (t) public; }) topics;
      inherit authEnvFile tokenDir;
    }
  );

  ntfyManage = pkgs.writeShellApplication {
    name = "ntfy-manage";
    runtimeInputs = [ pkgs.selfhost.ntfy-manage ];
    text = ''
      export NTFY_MANAGE_CONFIG=${configFile}
      exec ntfy-manage-bin "$@"
    '';
  };
in
{
  options.selfhost.notify.ntfy = {
    enable = lib.mkEnableOption "ntfy notification implementation (server + provisioning)";

    remotePublishers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              topic = lib.mkOption {
                type = lib.types.enum (lib.attrNames topics);
                description = "Topic this publisher may write to.";
              };
              tokenFile = lib.mkOption {
                type = lib.types.str;
                default = "${tokenDir}/${name}";
                description = "Where the provisioned token lands, root-owned 0400.";
              };
            };
          }
        )
      );
      default = { };
      description = "Publishers that run on another host. Their user, ACL and token are provisioned here; there is no secret transport between hosts, so copying the token into the other host's own secrets stays manual.";
    };
  };

  config = lib.mkIf cfg.notify.ntfy.enable {
    assertions = [
      {
        assertion = shadowedPublishers == [ ];
        message = "Remote publishers shadow a local service/task publisher of the same name: ${toString shadowedPublishers}";
      }
    ];

    selfhost = {
      services.ntfy = {
        displayName = lib.mkDefault "Ntfy";
        meta.homepage = lib.mkDefault "https://ntfy.sh";
        meta.description = lib.mkDefault "Push Notifications";
        meta.category = lib.mkDefault "monitoring";
        port = lib.mkDefault 2586;
        healthcheck.path = "/v1/health";
        integrations.homepage.group = lib.mkDefault "Admin";
      };

      notify.url = serviceCfg.url;
      notify.provisioningUnit = "ntfy-provision.service";

      runtimeSecrets.ntfy-admin-password = {
        restartUnits = [ "ntfy-provision.service" ];
      };

      # Reader accounts and their grants. The password hashes stay out: a leaked backup must not let
      # anyone read the fleet's notifications, and losing this costs one `reader add` per device.
      services.ntfy.backup.package = pkgs.writeShellApplication {
        name = "backup-ntfy";
        runtimeInputs = [ ntfyManage ];
        text = ''ntfy-manage status > "$OUTPUT_DIR/readers.txt"'';
      };
    };

    services.ntfy-sh = {
      enable = true;
      settings = {
        base-url = serviceCfg.publicUrl;
        listen-http = "${serviceCfg.host}:${toString serviceCfg.port}";
        behind-proxy = true;
        auth-default-access = "deny-all";
        enable-login = true;
      };
    };

    systemd.services.ntfy-sh.serviceConfig = {
      Restart = "on-failure";
      RestartSec = "10s";
      RestartMaxDelaySec = "5min";
      RestartSteps = 5;
      EnvironmentFile = [ authEnvFile ];
    };

    # The declared set changes only on a deploy, and the env file is what carries it into the server.
    systemd.services.ntfy-sh.restartTriggers = [ configFile ];

    systemd.tmpfiles.rules = [
      # 0700: tokens are root-owned and reach non-root consumers via LoadCredential, so nothing else traverses here.
      "d ${tokenDir} 0700 root root -"
    ];

    # Runs before the server rather than after it: rendering the env file needs no DB, since
    # `ntfy token generate` and `ntfy user hash` are both offline. ntfy then provisions from the env at
    # startup, so there is no health-poll and no second pass.
    systemd.services.ntfy-provision = {
      description = "ntfy declarative auth";
      before = [ "ntfy-sh.service" ];
      requiredBy = [ "ntfy-sh.service" ];
      restartTriggers = [
        configFile
        pkgs.selfhost.ntfy-manage
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        ExecStart = "${lib.getExe ntfyManage} provision";
        ReadWritePaths = [ secretsDir ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    environment.systemPackages = [ ntfyManage ];
  };
}
