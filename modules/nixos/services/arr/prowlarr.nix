# First-party Prowlarr app: framework wiring only (ingress, forward-auth, API key out of the store). Prowlarr
# is an indexer manager — the indexer/tracker list and the app-sync are acquisition config and stay in the
# consumer/private config, which reads `apps.prowlarr.apiKeyFile` and the target apps' `apiKeyFile`.
{
  config,
  lib,
  ...
}:
let
  cfg = config.selfhost;
  app = cfg.apps.prowlarr;
  apiKeySecret = "prowlarr-api-key";
  exporterUnit = "prometheus-exportarr-prowlarr-exporter";
in
{
  options.selfhost.apps.prowlarr = {
    enable = lib.mkEnableOption "the first-party Prowlarr app (indexer manager; wiring only, no indexers)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 9696;
      description = "Prowlarr listen port (localhost, behind ingress).";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = cfg.runtimeSecrets.${apiKeySecret}.path;
      defaultText = lib.literalMD "the generated API-key secret path";
      description = "Path to Prowlarr's generated API key, for the consumer indexer-sync reconciler.";
    };

    exporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9711;
      description = "exportarr listen port (localhost) for Prowlarr metrics. Each *arr needs its own — exportarr defaults them all to 9708.";
    };
  };

  config = lib.mkIf (cfg.enable && app.enable) {
    selfhost = {
      services.prowlarr = {
        displayName = "Prowlarr";
        meta.homepage = "https://prowlarr.com";
        meta.description = "Indexer Manager";
        meta.category = lib.mkDefault "downloads";
        inherit (app) port;
        healthcheck.path = "/ping";
        forwardAuth.enable = lib.mkDefault cfg.auth.forwardAuth.active;
        access.allowedGroups = lib.mkDefault [ cfg.groups.admin ];
        integrations.homepage.group = lib.mkDefault "Admin";
        # No queue here (an indexer manager imports nothing) — health is the whole signal.
        integrations.monitoring = {
          exporters."exportarr-prowlarr" = {
            enable = true;
            listenAddress = "127.0.0.1";
            port = app.exporterPort;
            url = cfg.services.prowlarr.url;
            apiKeyFile = cfg.runtimeSecrets.${apiKeySecret}.path;
          };
          scrapeConfigs = [
            {
              job_name = "prowlarr";
              static_configs = [
                {
                  targets = [ "127.0.0.1:${toString app.exporterPort}" ];
                  labels.instance = "prowlarr";
                }
              ];
            }
          ];
          rules = [
            {
              name = "prowlarr";
              rules = [
                {
                  alert = "ProwlarrHealthIssue";
                  # UpdateCheck fires until nixpkgs bumps the package: not actionable from inside the app.
                  expr = "prowlarr_system_health_issues{source!=\"UpdateCheck\"} > 0";
                  "for" = "15m";
                  labels.severity = "warning";
                  annotations.summary = "Prowlarr: {{ $labels.message }}";
                }
                {
                  alert = "ProwlarrCollectorError";
                  expr = "{__name__=~\"prowlarr_.*collector_error\"} > 0";
                  "for" = "15m";
                  labels.severity = "warning";
                  annotations.summary = "Prowlarr metrics collector failing";
                }
              ];
            }
          ];
          systemdOverrides.${exporterUnit} = {
            after = [ "prowlarr.service" ];
            wants = [ "prowlarr.service" ];
          };
        };
      };

      runtimeSecrets.${apiKeySecret} = {
        # exportarr rejects anything outside `^[a-zA-Z0-9]{20,32}`; the 64-char default never starts it.
        bytes = 16;
        restartUnits = [
          "prowlarr.service"
        ]
        ++ lib.optional cfg.services.prowlarr.integrations.monitoring.enable "${exporterUnit}.service";
      };
      runtimeTemplates."prowlarr.env" = {
        content = "PROWLARR__AUTH__APIKEY=${cfg.runtimePlaceholder.${apiKeySecret}}\n";
        restartUnits = [ "prowlarr.service" ];
      };
    };

    services.prowlarr = {
      enable = true;
      settings.server.port = app.port;
      settings.server.bindaddress = "127.0.0.1";
      environmentFiles = [ cfg.runtimeTemplates."prowlarr.env".path ];
    };

    # Indexer manager: talks to APIs, not the filesystem — no media mount needed.
    systemd.services.prowlarr = {
      environment = {
        PROWLARR__AUTH__METHOD = "External";
        PROWLARR__LOG__LEVEL = "info";
      };
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        RestartMaxDelaySec = "5min";
        RestartSteps = 5;
      };
    };
  };
}
