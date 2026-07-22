# Alertmanager: routes fired Prometheus alerts to the notify provider. Split from monitoring.nix so
# metrics collection and alert delivery stay one concern per file.
{
  config,
  lib,
  ...
}:
let
  cfg = config.selfhost;
  mon = cfg.monitoring;
  alertmanagerCfg = cfg.services.alertmanager;
in
{
  options.selfhost.monitoring.alertmanager = {
    enable = lib.mkEnableOption "Alertmanager alert delivery (routes fired alerts to notify)";
    port = lib.mkOption {
      type = lib.types.port;
      default = 9093;
      description = "Alertmanager listen port (localhost, behind ingress).";
    };
  };

  config = lib.mkIf mon.alertmanager.enable {
    assertions = [
      {
        assertion = mon.enable;
        message = "selfhost.monitoring.alertmanager.enable requires selfhost.monitoring.enable";
      }
      {
        # Alertmanager routes to notify: without an active provider the webhook URL is empty and its
        # notify-token is never provisioned, so the unit fails at runtime.
        assertion = cfg.notify.active;
        message = "selfhost.monitoring.alertmanager.enable requires an active notify provider (e.g. selfhost.notify.ntfy.enable).";
      }
    ];

    selfhost.services.alertmanager = {
      displayName = "Alertmanager";
      meta.homepage = "https://github.com/prometheus/alertmanager";
      meta.description = "Alert Routing";
      meta.category = lib.mkDefault "monitoring";
      port = mon.alertmanager.port;
      healthcheck.path = "/-/healthy";
      forwardAuth.enable = true;
      integrations.homepage.group = "Admin";
      integrations.notify = {
        enable = true;
        topic = lib.mkDefault "homelab-alert";
      };
    };

    selfhost.notify.topics."homelab-alert".public = lib.mkDefault false;

    services.prometheus = {
      alertmanagers = [
        {
          static_configs = [ { targets = [ "127.0.0.1:${toString alertmanagerCfg.port}" ]; } ];
        }
      ];

      alertmanager = {
        enable = true;
        listenAddress = alertmanagerCfg.host;
        inherit (alertmanagerCfg) port;
        configuration = {
          route = {
            receiver = "notify";
            group_by = [ "alertname" ];
            group_wait = "30s";
            group_interval = "5m";
            repeat_interval = "4h";
          };
          receivers = [
            {
              name = "notify";
              webhook_configs = [
                {
                  url = "${cfg.notify.url}/${alertmanagerCfg.integrations.notify.topic}?template=alertmanager";
                  send_resolved = true;
                  http_config.authorization = {
                    type = "Bearer";
                    credentials_file = "/run/credentials/alertmanager.service/notify-token";
                  };
                }
              ];
            }
          ];
        };
      };
    };

    systemd.services.alertmanager = {
      after = lib.optional (cfg.notify.provisioningUnit != null) cfg.notify.provisioningUnit;
      wants = lib.optional (cfg.notify.provisioningUnit != null) cfg.notify.provisioningUnit;
      serviceConfig.LoadCredential = [ "notify-token:${alertmanagerCfg.integrations.notify.tokenFile}" ];
    };
  };
}
