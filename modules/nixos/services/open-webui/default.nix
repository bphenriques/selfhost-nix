# First-party Open WebUI app: a chat UI in front of OpenAI-compatible backends. The framework wires
# ingress, the OIDC client and the identity model. Which backends, models, image pipelines or RAG it
# talks to is deployment config and stays with the consumer on `services.open-webui.environment`.
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
      description = ''
        The first-party Open WebUI app: a chat UI for OpenAI-compatible backends.

        Open WebUI is **unfree** in nixpkgs (its licence restricts removing the branding), so enabling
        this needs `nixpkgs.config.allowUnfree` or a predicate admitting `open-webui`. The framework
        will not set that for you. Every other bundled app is free software.
      '';
    };

  config = lib.mkIf (cfg.enable && app.enable) {
    selfhost = {
      services.open-webui = {
        displayName = lib.mkDefault "Open WebUI";
        meta.homepage = lib.mkDefault "https://github.com/open-webui/open-webui";
        meta.description = lib.mkDefault "Assistant Chat";
        meta.category = lib.mkDefault "productivity";
        # Not nixpkgs' 8080: RomM's API already owns that on loopback, and two bundled apps enabled
        # together should not collide out of the box.
        port = lib.mkDefault 8093;
        healthcheck.path = "/health";
        # Open WebUI keeps its own accounts either way, so it federates only where a provider exists.
        # Never forwardAuth: tinyauth decides by user-agent alone, so it answers this SPA's XHR with a
        # 302 the app cannot follow, and the UI reload-loops.
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

        # Otherwise the environment only *seeds* a config DB that then wins on every later boot, and
        # none of the settings here would stay declarative.
        ENABLE_PERSISTENT_CONFIG = lib.mkDefault "False";
        ENABLE_VERSION_UPDATE_CHECK = lib.mkDefault "False"; # nix owns the version

        # Restated, not re-asserted: nixpkgs ships these as the *default* of `environment`, and an
        # `attrsOf` default is discarded the moment anything defines the option. Setting one variable
        # would otherwise silently turn telemetry back on.
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
        # `access.model = "oidc"` routes this without a gateway in front, so the built-in form would be
        # a way to register past the provider and the groups it enforces.
        ENABLE_LOGIN_FORM = "False";
      };
    };

    # Left off `services.open-webui.environmentFile` so the consumer keeps it for its own credentials:
    # nixpkgs builds that into the same list, and systemd concatenates EnvironmentFile across entries.
    systemd.services.open-webui.serviceConfig = {
      EnvironmentFile = lib.mkIf federated [ cfg.runtimeTemplates."open-webui.env".path ];
      Restart = "on-failure";
      RestartSec = "10s";
      RestartMaxDelaySec = "5min";
      RestartSteps = 5;
    };
  };
}
