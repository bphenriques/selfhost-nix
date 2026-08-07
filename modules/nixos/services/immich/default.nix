# First-party Immich app. See the Immich docs chapter for the model.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.immich;
  serviceCfg = config.selfhost.services.immich;
  oidcCfg = config.selfhost.auth.oidc;

  enabledUsers = lib.filterAttrs (_: u: u.services.immich.enable) config.selfhost.users;

  users = lib.mapAttrsToList (_: u: {
    inherit (u) email name;
    inherit (u.services.immich) passwordFile storageLabel;
    isAdmin = u.services.immich.admin;
    quotaSizeInBytes = u.services.immich.quotaBytes;
    # A handed-out bootstrap password is meant to be replaced by its owner.
    shouldChangePassword = u.services.immich.passwordFile != null;
  }) enabledUsers;

  libraries = lib.concatLists (
    lib.mapAttrsToList (_: u: map (l: l // { ownerEmail = u.email; }) u.services.immich.libraries) enabledUsers
  );

  importPaths = lib.unique (lib.concatMap (l: l.importPaths) libraries);

  configFile = pkgs.writeText "immich-config.json" (
    builtins.toJSON {
      admin = {
        email = "admin@immich.local";
        name = "Immich Admin";
        passwordFile = config.selfhost.runtimeSecrets.immich-admin-password.path;
      };
      inherit users libraries;
    }
  );

  immich-configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "immich-configure";
    script = ./configure.nu;
  };
in
{
  imports = [ ./user.nix ];

  options.selfhost.apps.immich.enable = lib.mkEnableOption "the first-party Immich app (photo and video library)";

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost = {
      services.immich = {
        displayName = lib.mkDefault "Immich";
        meta.homepage = lib.mkDefault "https://immich.app";
        meta.description = lib.mkDefault "Photo & Video Gallery";
        meta.category = lib.mkDefault "media";
        port = lib.mkDefault 2283;
        healthcheck.path = "/api/server/ping";
        oidc = {
          enable = lib.mkDefault config.selfhost.auth.oidc.active;
          callbackURLs = lib.mkDefault [
            "${serviceCfg.publicUrl}/auth/login"
            "${serviceCfg.publicUrl}/user-settings"
            "app.immich:///oauth-callback"
          ];
          systemd.dependentServices = [ "immich-server" ];
        };
      };

      # Set once at admin sign-up and never reconciled, so losing the file means the next run cannot
      # authenticate and fails loudly. Restore it, or reset the password in Immich.
      runtimeSecrets.immich-admin-password = {
        owner = config.services.immich.user;
        restartUnits = [ "immich-configure.service" ];
      };
    };

    services.immich = {
      enable = true;
      inherit (serviceCfg) host port;
      # Storage and tuning stay at the nixpkgs defaults for the consumer to set.
      settings = {
        server.externalDomain = lib.mkDefault serviceCfg.publicUrl;
      }
      // lib.optionalAttrs serviceCfg.oidc.enable {
        oauth = {
          enabled = true;
          inherit (oidcCfg.provider) issuerUrl;
          clientId._secret = serviceCfg.oidc.id.file;
          clientSecret._secret = serviceCfg.oidc.secret.file;
          scope = lib.mkDefault "openid email profile";
          signingAlgorithm = lib.mkDefault "RS256";
          buttonText = lib.mkDefault "Login with ${oidcCfg.provider.displayName}";
          # OIDC only authenticates: Immich links a login to the declared account by email.
          autoRegister = lib.mkDefault false;
          autoLaunch = lib.mkDefault false;
        };
      };
    };

    systemd.services.immich-server.serviceConfig = {
      # Immich writes sidecars and thumbnails beside the originals it imports.
      ReadWritePaths = importPaths;
    }
    // lib.optionalAttrs serviceCfg.oidc.enable {
      SupplementaryGroups = serviceCfg.oidc.systemd.supplementaryGroups;
    };

    systemd.services.immich-configure = {
      description = "Reconcile Immich accounts and external libraries";
      wantedBy = [ "immich-server.service" ];
      after = [ "immich-server.service" ];
      requires = [ "immich-server.service" ];
      partOf = [ "immich-server.service" ];
      restartTriggers = [
        configFile
        immich-configure
      ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        User = config.services.immich.user;
        Group = config.services.immich.group;
        Restart = "on-failure";
        RestartSec = 10;
      };
      environment = {
        IMMICH_URL = serviceCfg.url;
        IMMICH_CONFIG_FILE = configFile;
      };
      script = lib.getExe immich-configure;
    };
  };
}
