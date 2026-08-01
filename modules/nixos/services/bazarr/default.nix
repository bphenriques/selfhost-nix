# First-party Bazarr app: subtitle automation for Radarr/Sonarr. Framework wiring (ingress, auth, secrets,
# metrics, backup) plus an idempotent reconcile. Ships no acquisition config — which subtitle providers to
# search, and with whose credentials, is the operator's and stays in their own config (see media docs).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  app = cfg.apps.bazarr;
  serviceCfg = cfg.services.bazarr;
  apiKeySecret = "bazarr-api-key";
  exporterUnit = "prometheus-exportarr-bazarr-exporter";

  configDir = "${app.dataDir}/config";
  configFile = "${configDir}/config.yaml";

  builders = import ../../builders.nix { inherit pkgs lib; };
  seedConfig = builders.writeNushellApplication {
    name = "bazarr-seed-config";
    script = ./seed-config.nu;
  };
  configure = builders.writeNushellApplication {
    name = "bazarr-configure";
    script = ./configure.nu;
  };

  arrLink =
    name:
    lib.optionalAttrs (app.${name} != null) {
      ${name} = {
        inherit (app.${name})
          host
          port
          baseUrl
          apiKeyFile
          ;
      };
    };

  reconcileJson = pkgs.writeText "bazarr-config.json" (
    builtins.toJSON (
      {
        inherit (app)
          languageProfiles
          defaultProfile
          settings
          secretSettings
          ;
      }
      // arrLink "sonarr"
      // arrLink "radarr"
    )
  );

  arrLinkModule = displayName: defaultPort: {
    options = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "${displayName} host reachable from Bazarr.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = defaultPort;
        description = "${displayName} port.";
      };
      baseUrl = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "${displayName} URL base.";
      };
      apiKeyFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to ${displayName}'s API key — typically `apps.${lib.toLower displayName}.apiKeyFile`.";
      };
    };
  };
in
{
  options.selfhost.apps.bazarr = {
    enable = lib.mkEnableOption "the first-party Bazarr app (subtitle automation; wiring + reconcile, no providers)";

    port = lib.mkOption {
      type = lib.types.port;
      default = 6767;
      description = "Bazarr listen port (localhost, behind ingress).";
    };

    exporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9712;
      description = "exportarr listen port (localhost) for Bazarr metrics.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/bazarr";
      description = "Bazarr state directory (config.yaml, database, logs).";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = cfg.runtimeSecrets.${apiKeySecret}.path;
      defaultText = lib.literalMD "the generated API-key secret path";
      description = "Path to Bazarr's generated API key.";
    };

    sonarr = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule (arrLinkModule "Sonarr" 8989));
      default = null;
      description = "Sonarr to pull the series library from. Null = Bazarr handles no TV.";
    };

    radarr = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule (arrLinkModule "Radarr" 7878));
      default = null;
      description = "Radarr to pull the movie library from. Null = Bazarr handles no movies.";
    };

    languageProfiles = lib.mkOption {
      default = [ ];
      description = ''
        Language profiles to ensure. Which languages to want is taste, so the framework ships none — with
        no profile Bazarr downloads nothing. The posted list is authoritative: a profile removed here is
        removed from Bazarr.
      '';
      example = lib.literalExpression ''
        [ { name = "English"; languages = [ "en" ]; cutoff = "en"; } ]
      '';
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Profile name.";
            };
            languages = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Two-letter language codes to search for, in priority order.";
            };
            cutoff = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Language that ends the search once found; null keeps searching for all of them.";
            };
          };
        }
      );
    };

    defaultProfile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Profile name applied to newly-added series and movies. Null leaves new media unassigned (nothing is fetched for it).";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
      default = { };
      description = ''
        Freeform `config.yaml` sections merged into the reconcile, as `<section>.<key>`. This is the seam
        for acquisition config: enabled providers and their per-provider options. Values that are secrets
        belong in `secretSettings`, not here — this lands in the world-readable Nix store.
      '';
      example = lib.literalExpression ''
        { general.enabled_providers = [ "someprovider" ]; }
      '';
    };

    secretSettings = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Settings whose values are read from a file at reconcile time, as `\"<section>.<key>\" = \"/path/to/secret\"`. For provider credentials.";
      example = lib.literalExpression ''
        { "someprovider.password" = "/run/secrets/someprovider-password"; }
      '';
    };

    configureAfter = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "sonarr.service" ];
      description = "Extra units the reconcile must start after and want — Bazarr connection-tests the *arrs it is given.";
    };
  };

  config = lib.mkIf (cfg.enable && app.enable) {
    assertions = [
      {
        assertion = app.defaultProfile == null || lib.any (p: p.name == app.defaultProfile) app.languageProfiles;
        message = "selfhost.apps.bazarr.defaultProfile '${toString app.defaultProfile}' is not one of languageProfiles.";
      }
    ];

    selfhost = {
      services.bazarr = {
        displayName = lib.mkDefault "Bazarr";
        meta.homepage = lib.mkDefault "https://www.bazarr.media";
        meta.description = lib.mkDefault "Subtitles";
        meta.category = lib.mkDefault "downloads";
        inherit (app) port;
        healthcheck.path = "/api/system/ping";
        forwardAuth.enable = lib.mkDefault cfg.auth.forwardAuth.active;
        access.allowedGroups = lib.mkDefault [ cfg.groups.admin ];
        integrations.homepage.icon = lib.mkDefault "bazarr.svg";
        integrations.monitoring = {
          exporters."exportarr-bazarr" = {
            enable = true;
            listenAddress = "127.0.0.1";
            port = app.exporterPort;
            url = "http://127.0.0.1:${toString app.port}";
            apiKeyFile = cfg.runtimeSecrets.${apiKeySecret}.path;
          };
          scrapeConfigs = [
            {
              job_name = "bazarr";
              static_configs = [
                {
                  targets = [ "127.0.0.1:${toString app.exporterPort}" ];
                  labels.instance = "bazarr";
                }
              ];
            }
          ];
          rules = [
            {
              name = "bazarr";
              rules = [
                {
                  alert = "BazarrHealthIssue";
                  expr = "bazarr_system_health_issues > 0";
                  "for" = "15m";
                  labels.severity = "warning";
                  annotations.summary = "Bazarr: {{ $labels.message }}";
                }
                {
                  alert = "BazarrCollectorError";
                  expr = "{__name__=~\"bazarr_.*collector_error\"} > 0";
                  "for" = "15m";
                  labels.severity = "warning";
                  annotations.summary = "Bazarr metrics collector failing";
                }
              ];
            }
          ];
          systemdOverrides.${exporterUnit} = {
            after = [ "bazarr.service" ];
            wants = [ "bazarr.service" ];
          };
        };
        backup = {
          after = [ "bazarr.service" ];
          package = pkgs.writeShellApplication {
            name = "backup-bazarr";
            runtimeInputs = [ pkgs.coreutils ];
            # The subtitle files themselves live beside the media; what is not reproducible is the
            # profile/assignment state, which is the database.
            text = ''
              cp "${app.dataDir}/db/bazarr.db" "$OUTPUT_DIR/bazarr.db"
            '';
          };
        };
      };

      runtimeSecrets.${apiKeySecret} = {
        # 32 hex chars: exportarr rejects anything outside `^[a-zA-Z0-9]{20,32}$`.
        bytes = 16;
        restartUnits = [
          "bazarr.service"
          "bazarr-configure.service"
        ]
        ++ lib.optional serviceCfg.integrations.monitoring.enable "${exporterUnit}.service";
      };

      # Surface reconcile failures — a Bazarr with no language profile silently fetches nothing.
      notify.topics."homelab-provision".public = lib.mkDefault false;
      tasks."bazarr-configure" = {
        systemdServices = [ "bazarr-configure" ];
        integrations.notify.topic = lib.mkDefault "homelab-provision";
      };
    };

    services.bazarr = {
      enable = true;
      listenPort = app.port;
      inherit (app) dataDir;
    };

    systemd.services.bazarr = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        ExecStartPre = lib.getExe seedConfig;
        # Bazarr runs unprivileged and the generated secret is root-only; LoadCredential bridges the two
        # (systemd reads it as root before the user drop) and covers ExecStartPre as well as ExecStart.
        LoadCredential = [ "api-key:${cfg.runtimeSecrets.${apiKeySecret}.path}" ];
        Restart = "on-failure";
        RestartSec = "10s";
        RestartMaxDelaySec = "5min";
        RestartSteps = 5;
      };
      environment = {
        BAZARR_CONFIG_FILE = configFile;
        BAZARR_API_KEY_FILE = "%d/api-key";
      };
    };

    systemd.services.bazarr-configure = {
      description = "Bazarr reconcile (*arr links, language profiles, providers)";
      wantedBy = [ "bazarr.service" ];
      after = [ "bazarr.service" ] ++ app.configureAfter;
      requires = [ "bazarr.service" ];
      wants = app.configureAfter;
      partOf = [ "bazarr.service" ];
      restartTriggers = [
        reconcileJson
        configure
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
        BAZARR_URL = serviceCfg.url;
        BAZARR_API_KEY_FILE = cfg.runtimeSecrets.${apiKeySecret}.path;
        BAZARR_CONFIG_FILE = reconcileJson;
      };
      script = lib.getExe configure;
    };
  };
}
