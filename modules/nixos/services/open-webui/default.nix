# Open WebUI app. Backends, models, image pipelines and RAG are the consumer's, on `services.open-webui.environment`.
{
  config,
  lib,
  ...
}:
let
  cfg = config.selfhost;
  app = cfg.apps.open-webui;
  serviceCfg = cfg.services.open-webui;
  oidcCfg = cfg.auth.oidc;

  federated = serviceCfg.access.model == "oidc";
in
{
  options.selfhost.apps.open-webui.enable =
    lib.mkEnableOption "the first-party Open WebUI app (chat UI for OpenAI-compatible backends)"
    // {
      description = "The Open WebUI app. Unfree in nixpkgs, so allow `open-webui` in your unfree predicate.";
    };

  config = lib.mkIf app.enable {
    selfhost = {
      services.open-webui = {
        displayName = lib.mkDefault "Open WebUI";
        meta.homepage = lib.mkDefault "https://github.com/open-webui/open-webui";
        meta.description = lib.mkDefault "Assistant Chat";
        meta.category = lib.mkDefault "productivity";
        # Not nixpkgs' 8080, which RomM's API already owns on loopback.
        port = lib.mkDefault 8093;
        healthcheck.path = "/health";
        # Never forwardAuth: tinyauth answers this SPA's XHR with a 302 it cannot follow, and the UI reload-loops.
        access.model = lib.mkDefault (if oidcCfg.active then "oidc" else "native");
        access.oidc = {
          # Both routes decorate one handler, and `url_for` resolves to whichever registered first.
          callbackURLs = lib.mkDefault [
            "${serviceCfg.publicUrl}/oauth/oidc/callback"
            "${serviceCfg.publicUrl}/oauth/oidc/login/callback"
          ];
          systemd.dependentServices = [ "open-webui" ];
        };
      };

      # Read from the environment because Open WebUI ships no `_FILE` convention for these two.
      runtimeTemplates."open-webui.env" = lib.mkIf federated {
        content = ''
          OAUTH_CLIENT_ID=${cfg.oidcPlaceholder.open-webui.id}
          OAUTH_CLIENT_SECRET=${cfg.oidcPlaceholder.open-webui.secret}
        '';
        restartUnits = [ "open-webui.service" ];
      };
    };

    services.open-webui = {
      enable = true;
      inherit (serviceCfg) host port;

      environment = {
        WEBUI_URL = lib.mkDefault serviceCfg.publicUrl;

        # Otherwise the environment only seeds a config DB that wins on every later boot.
        ENABLE_PERSISTENT_CONFIG = lib.mkDefault "False";
        ENABLE_VERSION_UPDATE_CHECK = lib.mkDefault "False"; # nix owns the version

        # Restated: defining `environment` discards nixpkgs' default, which would silently turn telemetry back on.
        SCARF_NO_ANALYTICS = lib.mkDefault "True";
        DO_NOT_TRACK = lib.mkDefault "True";
        ANONYMIZED_TELEMETRY = lib.mkDefault "False";
      }
      // lib.optionalAttrs federated {
        OPENID_PROVIDER_URL = oidcCfg.provider.discoveryUrl;
        OAUTH_PROVIDER_NAME = oidcCfg.provider.displayName;
        OAUTH_SCOPES = lib.mkDefault "openid email profile";
        ENABLE_OAUTH_SIGNUP = lib.mkDefault "True";
        OAUTH_MERGE_ACCOUNTS_BY_EMAIL = lib.mkDefault "True"; # safe only because the provider verifies addresses
        # Routed without a gateway, so the built-in signup would bypass the provider and its groups.
        ENABLE_LOGIN_FORM = "False";
      };
    };

    # Left free for the consumer's own credentials; systemd concatenates EnvironmentFile entries.
    systemd.services.open-webui.serviceConfig = {
      EnvironmentFile = lib.mkIf federated [ cfg.runtimeTemplates."open-webui.env".path ];
      Restart = "on-failure";
      RestartSec = "10s";
      RestartMaxDelaySec = "5min";
      RestartSteps = 5;
    };
  };
}
