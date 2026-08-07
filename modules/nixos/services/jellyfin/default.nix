# First-party Jellyfin app. See the Jellyfin docs chapter for the model.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.jellyfin;
  serviceCfg = config.selfhost.services.jellyfin;

  enabledUsers = lib.filterAttrs (_: u: u.services.jellyfin.enable) config.selfhost.users;

  configFile = pkgs.writeText "jellyfin-config.json" (
    builtins.toJSON {
      inherit (app)
        serverName
        startup
        branding
        encoding
        trickplay
        libraries
        ;
      users = lib.mapAttrsToList (_: u: {
        inherit (u) username;
        inherit (u.services.jellyfin) passwordFile;
        policy = app.defaultPolicy // u.services.jellyfin.policy;
      }) enabledUsers;
    }
  );

  jellyfin-configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "jellyfin-configure";
    script = ./configure.nu;
  };

  libraryModule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Library name in Jellyfin; also its reconcile identity, so renaming creates a second one.";
      };
      collectionType = lib.mkOption {
        type = lib.types.enum [
          "unknown"
          "movies"
          "tvshows"
          "music"
          "musicvideos"
          "trailers"
          "homevideos"
          "boxsets"
          "books"
          "photos"
          "livetv"
          "playlists"
          "folders"
        ];
        example = "movies";
        description = "Jellyfin collection type. Closed set, so a typo fails evaluation rather than the library create.";
      };
      locations = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Directories this library scans. Reconciled, so moving a path moves the library.";
      };
      options = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        example = {
          EnableRealtimeMonitor = false;
        };
        description = "Fields merged into this library's Jellyfin LibraryOptions, applied verbatim.";
      };
    };
  };
in
{
  imports = [ ./user.nix ];

  options.selfhost.apps.jellyfin = {
    enable = lib.mkEnableOption "the first-party Jellyfin app (media server)";

    serverName = lib.mkOption {
      type = lib.types.str;
      default = serviceCfg.displayName;
      defaultText = lib.literalMD "the service's `displayName`";
      description = "Server name Jellyfin reports to clients.";
    };

    startup = {
      uiCulture = lib.mkOption {
        type = lib.types.str;
        default = "en-US";
        description = "Interface culture, applied once by the startup wizard.";
      };
      metadataCountryCode = lib.mkOption {
        type = lib.types.str;
        default = "US";
        description = "Metadata country code, applied once by the startup wizard.";
      };
      preferredMetadataLanguage = lib.mkOption {
        type = lib.types.str;
        default = "en";
        description = "Preferred metadata language, applied once by the startup wizard.";
      };
    };

    libraries = lib.mkOption {
      type = lib.types.listOf libraryModule;
      default = [ ];
      description = "Libraries to create and keep pointed at their directories.";
    };

    defaultPolicy = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        EnableSubtitleManagement = true;
      };
      description = "Policy fields applied to every account, under each user's own `policy`. The baseline most deployments want the same for everyone.";
    };

    branding = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Fields merged into Jellyfin's branding configuration. Merged, not replaced, so a login disclaimer owned by an SSO plugin survives.";
    };

    encoding = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = {
        TonemappingAlgorithm = "bt2390";
      };
      description = ''
        EncodingOptions fields, merged onto what Jellyfin holds and applied through the API after startup,
        so anything not named here keeps its value.

        `services.jellyfin.hardwareAcceleration` and `services.jellyfin.transcoding` cover part of the same
        ground by writing `encoding.xml` directly. Use one or the other, never both: together the file
        always differs from the generated template, and each restart leaves another
        `encoding.xml.backup-<timestamp>` behind.

        Unknown keys are dropped silently, since Jellyfin ignores properties it does not recognise.
      '';
    };

    trickplay = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      description = "Fields merged into Jellyfin's trickplay options.";
    };
  };

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost = {
      services.jellyfin = {
        displayName = lib.mkDefault "Jellyfin";
        meta.homepage = lib.mkDefault "https://jellyfin.org";
        meta.description = lib.mkDefault "Media Player";
        meta.category = lib.mkDefault "media";
        port = lib.mkDefault 8096;
        healthcheck.path = "/health";
        # Jellyfin authenticates its own clients, and native apps cannot pass a forward-auth gateway.
        forwardAuth.enable = lib.mkDefault false;
      };

      # Set once by the startup wizard and never reconciled, so losing the file means the next run cannot
      # authenticate and fails loudly. Restore it, or reset the password in Jellyfin.
      runtimeSecrets.jellyfin-admin-password.restartUnits = [ "jellyfin-configure.service" ];
    };

    services.jellyfin.enable = true;

    systemd.services.jellyfin-configure = {
      description = "Reconcile Jellyfin settings, libraries and accounts";
      wantedBy = [ "jellyfin.service" ];
      after = [ "jellyfin.service" ];
      requires = [ "jellyfin.service" ];
      partOf = [ "jellyfin.service" ];
      restartTriggers = [
        configFile
        jellyfin-configure
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
        JELLYFIN_URL = serviceCfg.url;
        JELLYFIN_ADMIN_USERNAME = "admin";
        JELLYFIN_ADMIN_PASSWORD_FILE = config.selfhost.runtimeSecrets.jellyfin-admin-password.path;
        JELLYFIN_CONFIG_FILE = configFile;
      };
      script = lib.getExe jellyfin-configure;
    };
  };
}
