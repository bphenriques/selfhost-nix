# First-party Miniflux app: an RSS reader fronted by OIDC. Users auto-provision on first OIDC login; a
# local CREATE_ADMIN account (random password, root-readable) covers admin tasks. No per-user reconciler
# — reader preferences live in the UI, not declared here. Promote an OIDC user to admin manually (via the
# local admin) if ever needed; the API mapping isn't worth maintaining.
{ config, lib, ... }:
let
  app = config.selfhost.apps.miniflux;
  serviceCfg = config.selfhost.services.miniflux;
  oidcCfg = config.selfhost.auth.oidc;
in
{
  options.selfhost.apps.miniflux.enable = lib.mkEnableOption "the first-party Miniflux app (RSS reader with OIDC login)";

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost = {
      services.miniflux = {
        displayName = lib.mkDefault "Miniflux";
        description = lib.mkDefault "RSS Reader";
        port = lib.mkDefault 8081;
        access.allowedGroups = lib.mkDefault [ config.selfhost.groups.admin ];
        healthcheck.path = "/healthcheck";
        oidc = {
          enable = true; # Miniflux's auth model here is OIDC; the local admin is bootstrap-only.
          systemd.dependentServices = [ "miniflux" ];
        };
      };

      # Bootstrap admin: auto-generated random password (root-readable), rarely used since login is OIDC.
      runtimeSecrets.miniflux-admin-password.restartUnits = [ "miniflux.service" ];
      runtimeTemplates."miniflux-admin-credentials.env" = {
        content = ''
          ADMIN_USERNAME=admin
          ADMIN_PASSWORD=${config.selfhost.runtimePlaceholder.miniflux-admin-password}
        '';
        restartUnits = [ "miniflux.service" ];
      };
    };

    services.miniflux = {
      enable = true;
      createDatabaseLocally = true;
      adminCredentialsFile = config.selfhost.runtimeTemplates."miniflux-admin-credentials.env".path;
      config = {
        LISTEN_ADDR = "127.0.0.1:${toString serviceCfg.port}";
        BASE_URL = serviceCfg.publicUrl;
        RUN_MIGRATIONS = true;
        CREATE_ADMIN = true;
        DISABLE_LOCAL_AUTH = 0; # keep the local admin able to log in alongside OIDC

        OAUTH2_USER_CREATION = 1;
        OAUTH2_PROVIDER = "oidc";
        OAUTH2_REDIRECT_URL = builtins.head serviceCfg.oidc.callbackURLs;
        OAUTH2_OIDC_DISCOVERY_ENDPOINT = oidcCfg.provider.issuerUrl;
        OAUTH2_OIDC_PROVIDER_NAME = oidcCfg.provider.displayName;
        OAUTH2_CLIENT_ID_FILE = serviceCfg.oidc.id.file;
        OAUTH2_CLIENT_SECRET_FILE = serviceCfg.oidc.secret.file;
      };
    };

    systemd.services.miniflux.serviceConfig.SupplementaryGroups = serviceCfg.oidc.systemd.supplementaryGroups;
    systemd.services.miniflux-dbsetup.serviceConfig.RemainAfterExit = true; # oneshot must stay active to satisfy start-limit
  };
}
