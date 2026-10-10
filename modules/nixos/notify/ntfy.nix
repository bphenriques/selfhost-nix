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
  # Upstream's, so the backup hook reads whatever the server was told to use rather than guessing.
  authFile = config.services.ntfy-sh.settings.auth-file;

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
    inherit (r) topics tokenFile;
  }) cfg.notify.ntfy.remotePublishers;

  allPublishers = localPublishers // remotePublishers;
  shadowedPublishers = lib.intersectLists (lib.attrNames cfg.notify.ntfy.remotePublishers) (
    lib.attrNames localPublishers
  );
  unusedTopics = lib.subtractLists (lib.unique (lib.concatMap (p: p.topics) (lib.attrValues allPublishers))) (
    lib.attrNames topics
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
              topics = lib.mkOption {
                type = lib.types.nonEmptyListOf (lib.types.enum (lib.attrNames topics));
                description = "Topics this publisher may write to. A remote task that routes failures separately needs both its topic and its failureTopic here, since this host cannot read the other one's config.";
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
      {
        # Nothing self-registers a topic, so a declared one no publisher writes to is dead weight. Checked
        # here rather than in the neutral layer because only the provider sees the remote publishers too.
        assertion = unusedTopics == [ ];
        message = "selfhost.notify.topics declares topics no publisher writes to: ${toString unusedTopics}. Remove them, or point a publisher at them.";
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

      # Only what a rebuild cannot put back: reader accounts, and the per-account preferences that hold
      # each client's subscription list. Publishers, grants and tokens are all reconciled from Nix, so
      # dumping them would back up the repo. Password hashes and tokens stay out: a leaked backup must
      # not read the fleet's notifications, and losing this costs one `reader add` per device.
      services.ntfy.backup.package = pkgs.writeShellApplication {
        name = "backup-ntfy";
        runtimeInputs = [ pkgs.sqlite ];
        text = ''
          sqlite3 -readonly ${authFile} \
            "select user, role, prefs from user where provisioned = 0 and user <> '*';" \
            > "$OUTPUT_DIR/readers.txt"
          sqlite3 -readonly ${authFile} \
            "select u.user, a.topic, a.read, a.write from user_access a join user u on a.user_id = u.id where a.provisioned = 0;" \
            > "$OUTPUT_DIR/reader-grants.txt"
        '';
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
