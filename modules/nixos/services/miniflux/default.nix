# First-party Miniflux app: an OIDC-fronted RSS reader; per-user settings reconciled via configure.nu.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.miniflux;
  serviceCfg = config.selfhost.services.miniflux;
  oidcCfg = config.selfhost.auth.oidc;

  # OIDC users get a Miniflux account on first login; their settings (admin + freeform prefs) are reconciled.
  enabledUsers = lib.filterAttrs (_: u: u.auth.oidc.enable) config.selfhost.users;
  usersFile = pkgs.writeText "miniflux-users.json" (
    builtins.toJSON (
      lib.mapAttrsToList (_: u: {
        inherit (u) username;
        # is_admin is framework-controlled, so it wins over any value placed in the freeform settings.
        settings = u.services.miniflux.settings // {
          is_admin = u.isAdmin;
        };
      }) enabledUsers
    )
  );

  miniflux-configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "miniflux-configure";
    script = ./configure.nu;
  };
in
{
  imports = [ ./user.nix ];

  options.selfhost.apps.miniflux.enable = lib.mkEnableOption "the first-party Miniflux app (RSS reader with OIDC login)";

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost = {
      services.miniflux = {
        displayName = lib.mkDefault "Miniflux";
        meta.homepage = lib.mkDefault "https://miniflux.app";
        meta.description = lib.mkDefault "RSS Reader";
        meta.category = lib.mkDefault "productivity";
        port = lib.mkDefault 8081;
        access.allowedGroups = lib.mkDefault [ config.selfhost.groups.admin ];
        healthcheck.path = "/healthcheck";
        oidc = {
          enable = true;
          systemd.dependentServices = [ "miniflux" ];
        };
      };

      # Bootstrap admin: auto-generated random password (root-readable), rarely used since login is OIDC.
      runtimeSecrets.miniflux-admin-password.restartUnits = [
        "miniflux.service"
        "miniflux-configure.service"
      ];
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
      # Database is the consumer's deployment concern: nixpkgs already defaults to a local Postgres; leave
      # it unset so `createDatabaseLocally = false` + a DATABASE_URL for external Postgres composes cleanly.
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

    systemd.services.miniflux-configure = {
      description = "Reconcile per-user Miniflux settings (admin + freeform preferences)";
      wantedBy = [ "miniflux.service" ];
      after = [ "miniflux.service" ];
      requires = [ "miniflux.service" ];
      partOf = [ "miniflux.service" ];
      restartTriggers = [
        usersFile
        miniflux-configure
      ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        Restart = "on-failure";
        RestartSec = 10;
      };
      environment = {
        MINIFLUX_URL = serviceCfg.url;
        MINIFLUX_ADMIN_USERNAME = "admin";
        MINIFLUX_ADMIN_PASSWORD_FILE = config.selfhost.runtimeSecrets.miniflux-admin-password.path;
        MINIFLUX_USERS_FILE = usersFile;
      };
      script = lib.getExe miniflux-configure;
    };
  };
}
