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
  };

  config = lib.mkIf (cfg.enable && app.enable) {
    selfhost = {
      services.prowlarr = {
        displayName = "Prowlarr";
        description = "Indexer Manager";
        inherit (app) port;
        healthcheck.path = "/ping";
        forwardAuth.enable = lib.mkDefault cfg.auth.forwardAuth.active;
        access.allowedGroups = lib.mkDefault [ cfg.groups.admin ];
        integrations.homepage.group = lib.mkDefault "Admin";
      };

      runtimeSecrets.${apiKeySecret}.restartUnits = [ "prowlarr.service" ];
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
