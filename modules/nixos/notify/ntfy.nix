# Runs the ntfy-sh server and provisions topics/publisher tokens.
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

  tokenDir = "/var/lib/homelab-secrets/notify-publishers";

  notifyServices = lib.filterAttrs (_: s: s.integrations.notify.enable) cfg.services;
  servicePublishers = lib.mapAttrs (_: s: { inherit (s.integrations.notify) topic tokenFile; }) notifyServices;

  notifyTasks = lib.filterAttrs (_: t: t.integrations.notify.enable) cfg.tasks;
  taskPublishers = lib.mapAttrs (_: t: { inherit (t.integrations.notify) topic tokenFile; }) notifyTasks;

  localPublishers = servicePublishers // taskPublishers;
  allPublishers = localPublishers // cfg.notify.ntfy.remotePublishers;
  shadowedPublishers = lib.intersectLists (lib.attrNames cfg.notify.ntfy.remotePublishers) (
    lib.attrNames localPublishers
  );

  configFile = pkgs.writeText "ntfy-configure.json" (
    builtins.toJSON {
      publicTopics = lib.attrNames (lib.filterAttrs (_: t: t.public) topics);
      publishers = allPublishers;
    }
  );
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
      notify.provisioningUnit = "ntfy-configure.service";

      runtimeSecrets.ntfy-admin-password = {
        restartUnits = [
          "ntfy-sh.service"
          "ntfy-configure.service"
        ];
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
    };

    systemd.tmpfiles.rules = [
      # 0700: tokens are root-owned and reach non-root consumers via LoadCredential, so nothing else traverses here.
      "d ${tokenDir} 0700 root root -"
    ];

    systemd.services.ntfy-configure = {
      description = "ntfy setup";
      wantedBy = [ "ntfy-sh.service" ];
      after = [ "ntfy-sh.service" ];
      requires = [ "ntfy-sh.service" ];
      partOf = [ "ntfy-sh.service" ];
      restartTriggers = [
        configFile
        pkgs.selfhost.ntfy-manage
      ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        Restart = "on-failure";
        RestartSec = 10;
        UMask = "0077";
      };
      environment = {
        NTFY_ADMIN_PASSWORD_FILE = cfg.runtimeSecrets.ntfy-admin-password.path;
        NTFY_PROVISION_FILE = configFile;
        # `ntfy user add` needs the server's auth DB, which only exists once it has started;
        # `after = ntfy-sh.service` isn't enough, so the script polls this health endpoint first.
        NTFY_BASE_URL = serviceCfg.url;
      };
      script = lib.getExe pkgs.selfhost.ntfy-manage;
    };
  };
}
