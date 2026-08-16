# Builder for a media *arr (Radarr/Sonarr): framework wiring (ingress, auth, secrets, notify, backup) plus an
# idempotent reconcile. Ships no acquisition config — all caller-supplied, empty by default (see media docs).
{
  name,
  displayName,
  description,
  homepage,
  defaultPort,
  icon,
  notifyTags,
  backupResource, # { path = "movie"|"series"; file = "movies.json"; } — the library list to snapshot
  defaultExporterPort,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  app = cfg.apps.${name};
  serviceCfg = cfg.services.${name};
  apiKeySecret = "${name}-api-key";
  envPrefix = lib.toUpper name;
  exporterUnit = "prometheus-exportarr-${name}-exporter";

  configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "${name}-configure";
    script = ./configure.nu;
  };

  notifyEnabled = serviceCfg.integrations.notify.enable && serviceCfg.integrations.notify.topic != null;

  configJson = pkgs.writeText "${name}-arr-config.json" (
    builtins.toJSON (
      {
        rootFolders = map (
          r: { inherit (r) path; } // lib.optionalAttrs (r.defaultQualityProfile != null) { inherit (r) defaultQualityProfile; }
        ) app.rootFolders;
        downloadClients = map (c: {
          inherit (c)
            name
            implementation
            protocol
            fields
            ;
        }) app.downloadClients;
      }
      // lib.optionalAttrs (app.delayProfile != null) { inherit (app) delayProfile; }
      // lib.optionalAttrs notifyEnabled {
        notification = {
          serverUrl = cfg.notify.url;
          topic = serviceCfg.integrations.notify.topic;
          tags = notifyTags;
          onImport = app.notifyOnImport;
        };
      }
    )
  );
in
{
  options.selfhost.apps.${name} = {
    enable = lib.mkEnableOption "the first-party ${displayName} app (media automation; ingress + auth + secrets wired, zero acquisition config)";

    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = cfg.runtimeSecrets.${apiKeySecret}.path;
      defaultText = lib.literalMD "the generated API-key secret path";
      description = "Path to ${displayName}'s generated API key, for consumer reconcilers (e.g. Prowlarr sync, recyclarr).";
    };

    exporterPort = lib.mkOption {
      type = lib.types.port;
      default = defaultExporterPort;
      description = "exportarr listen port (localhost) for ${displayName} metrics. Each *arr needs its own — exportarr defaults them all to 9708.";
    };

    rootFolders = lib.mkOption {
      default = [ ];
      description = "Root library folders to ensure. Paths only — storage/protocol-agnostic.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            path = lib.mkOption {
              type = lib.types.str;
              description = "Library path (must exist on disk; typically a selfhost storage mount).";
            };
            defaultQualityProfile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Name of a quality profile (consumer/recyclarr-managed) to seed as this folder's default; null = none.";
            };
          };
        }
      );
    };

    downloadClients = lib.mkOption {
      default = [ ];
      description = "Download clients to register. The framework applies them via the *arr schema; it ships none and assumes no protocol.";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Client name in ${displayName}.";
            };
            implementation = lib.mkOption {
              type = lib.types.str;
              description = ''The *arr download-client implementation (e.g. "Transmission", "Sabnzbd"). No default — you choose.'';
            };
            protocol = lib.mkOption {
              type = lib.types.enum [
                "torrent"
                "usenet"
              ];
              description = "Client protocol.";
            };
            fields = lib.mkOption {
              type = lib.types.attrsOf lib.types.anything;
              default = { };
              description = "Implementation-specific fields passed through to the client schema (host, port, category, …).";
            };
          };
        }
      );
    };

    delayProfile = lib.mkOption {
      default = null;
      description = "Optional default delay profile. Null = leave ${displayName}'s own default untouched. Carries the protocol preference — acquisition taste, no framework default.";
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            enableUsenet = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this profile may grab usenet releases.";
            };
            enableTorrent = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether this profile may grab torrent releases.";
            };
            preferredProtocol = lib.mkOption {
              type = lib.types.enum [
                "torrent"
                "usenet"
              ];
              description = "Protocol preference.";
            };
            usenetDelay = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = "Minutes to hold a usenet release before grabbing it, letting a better one appear first.";
            };
            torrentDelay = lib.mkOption {
              type = lib.types.int;
              default = 0;
              description = "Minutes to hold a torrent release before grabbing it, letting a better one appear first.";
            };
            bypassIfHighestQuality = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Grab immediately, ignoring the delays above, when the release already meets the highest wanted quality.";
            };
          };
        }
      );
    };

    notifyOnImport = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Publish a notification when an item is imported or upgraded. Turn this off when something
        downstream already tells people content arrived (a request manager, for example) — otherwise one
        arrival produces two messages describing the same thing. The failure events (health checks, manual
        interaction required) are always published and are not affected by this.
      '';
    };

    configureAfter = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "transmission.service" ];
      description = "Extra units the reconcile must start after and want. ${displayName} connection-tests a download client on save, so order this after the client's service (e.g. your torrent/usenet daemon).";
    };
  };

  config = lib.mkIf (cfg.enable && app.enable) {
    selfhost = {
      services.${name} = {
        displayName = lib.mkDefault displayName;
        meta.description = lib.mkDefault description;
        meta.homepage = lib.mkDefault homepage;
        meta.category = lib.mkDefault "downloads";
        port = lib.mkDefault defaultPort;
        healthcheck.path = "/ping";
        # The reconcile sets AUTH__METHOD=External, so ${displayName} serves no login of its own.
        access.model = "forwardAuth";
        access.allowedGroups = lib.mkDefault [ cfg.groups.admin ];
        integrations.homepage.icon = lib.mkDefault icon;
        integrations.monitoring = {
          exporters."exportarr-${name}" = {
            enable = true;
            listenAddress = "127.0.0.1";
            port = app.exporterPort;
            inherit (serviceCfg) url;
            apiKeyFile = cfg.runtimeSecrets.${apiKeySecret}.path;
            # Default `info` logs a line per upstream HTTP call, i.e. several per scrape, forever.
            environment.LOG_LEVEL = lib.mkDefault "warn";
          };
          scrapeConfigs = [
            {
              job_name = name;
              static_configs = [
                {
                  targets = [ "127.0.0.1:${toString app.exporterPort}" ];
                  labels.instance = name;
                }
              ];
            }
          ];
          rules = [
            {
              inherit name;
              rules = [
                {
                  alert = "${displayName}HealthIssue";
                  # UpdateCheck fires until nixpkgs bumps the package: not actionable from inside the app.
                  expr = "${name}_system_health_issues{source!=\"UpdateCheck\"} > 0";
                  "for" = "15m";
                  labels.severity = "warning";
                  annotations.summary = "${displayName}: {{ $labels.message }}";
                }
                {
                  # Never completes, so the client is never told to remove it.
                  alert = "${displayName}QueueStuck";
                  expr = "${name}_queue_total{download_status=~\"warning|error\"} > 0";
                  "for" = "2h";
                  labels.severity = "warning";
                  annotations.summary = "${displayName} queue stuck ({{ $labels.download_state }})";
                }
                {
                  alert = "${displayName}CollectorError";
                  expr = "{__name__=~\"${name}_.*collector_error\"} > 0";
                  "for" = "15m";
                  labels.severity = "warning";
                  annotations.summary = "${displayName} metrics collector failing";
                }
              ];
            }
          ];
          systemdOverrides.${exporterUnit} = {
            after = [ "${name}.service" ];
            wants = [ "${name}.service" ];
          };
        };
        backup = {
          after = [ "${name}.service" ];
          package = pkgs.writeShellApplication {
            name = "backup-${name}";
            runtimeInputs = [ pkgs.curl ];
            text = ''
              key="$(cat "${cfg.runtimeSecrets.${apiKeySecret}.path}")"
              curl --fail --silent --show-error --location \
                --header "X-Api-Key: $key" \
                --output "$OUTPUT_DIR/${backupResource.file}" \
                "${serviceCfg.url}/api/v3/${backupResource.path}"
            '';
          };
        };
      };

      runtimeSecrets.${apiKeySecret} = {
        # exportarr rejects anything outside `^[a-zA-Z0-9]{20,32}`; the 64-char default never starts it.
        bytes = 16;
        restartUnits = [
          "${name}.service"
          "${name}-configure.service"
        ]
        # restartUnits declares unit ordering, so naming an uninstantiated exporter leaves a stub unit.
        ++ lib.optional serviceCfg.integrations.monitoring.enable "${exporterUnit}.service";
      };
      runtimeTemplates."${name}.env" = {
        content = "${envPrefix}__AUTH__APIKEY=${cfg.runtimePlaceholder.${apiKeySecret}}\n";
        restartUnits = [ "${name}.service" ];
      };

      # Surface reconcile failures (else a broken library config is silent until you notice missing media).
      notify.topics."homelab-provision".public = lib.mkDefault false;
      tasks."${name}-configure" = {
        systemdServices = [ "${name}-configure" ];
        integrations.notify.topic = lib.mkDefault "homelab-provision";
      };
    };

    services.${name} = {
      enable = true;
      settings.server.port = serviceCfg.port;
      settings.server.bindaddress = "127.0.0.1";
      environmentFiles = [ cfg.runtimeTemplates."${name}.env".path ];
    };

    systemd.services.${name} = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      environment = {
        "${envPrefix}__AUTH__METHOD" = "External"; # trust the forward-auth identity header; no login UI
        "${envPrefix}__LOG__LEVEL" = "info";
      };
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        RestartMaxDelaySec = "5min";
        RestartSteps = 5;
      };
    };

    systemd.services."${name}-configure" = {
      description = "${displayName} reconcile (root folders, download clients, notify)";
      # Activation only restarts running units, so a reconcile left stopped would never pick up its fix.
      wantedBy = [ "multi-user.target" ];
      after = [
        "${name}.service"
      ]
      ++ app.configureAfter
      ++ lib.optional (notifyEnabled && cfg.notify.provisioningUnit != null) cfg.notify.provisioningUnit;
      requires = [ "${name}.service" ];
      wants =
        app.configureAfter ++ lib.optional (notifyEnabled && cfg.notify.provisioningUnit != null) cfg.notify.provisioningUnit;
      partOf = [ "${name}.service" ];
      restartTriggers = [
        configJson
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
        ARR_NAME = displayName;
        ARR_URL = serviceCfg.url;
        ARR_API_KEY_FILE = cfg.runtimeSecrets.${apiKeySecret}.path;
        ARR_CONFIG_FILE = configJson;
      }
      // lib.optionalAttrs notifyEnabled {
        NTFY_TOKEN_FILE = serviceCfg.integrations.notify.tokenFile;
      };
      script = lib.getExe configure;
    };
  };
}
