# Builder for a media *arr (Radarr/Sonarr): framework wiring (ingress, auth, secrets, notify, backup) plus an
# idempotent reconcile. Ships no acquisition config — all caller-supplied, empty by default (see media docs).
{
  name,
  displayName,
  description,
  defaultPort,
  icon,
  notifyTags,
  backupResource, # { path = "movie"|"series"; file = "movies.json"; } — the library list to snapshot
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
        };
      }
    )
  );
in
{
  options.selfhost.apps.${name} = {
    enable = lib.mkEnableOption "the first-party ${displayName} app (media automation; ingress + auth + secrets wired, zero acquisition config)";

    port = lib.mkOption {
      type = lib.types.port;
      default = defaultPort;
      description = "${displayName} listen port (localhost, behind ingress).";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = cfg.runtimeSecrets.${apiKeySecret}.path;
      defaultText = lib.literalMD "the generated API-key secret path";
      description = "Path to ${displayName}'s generated API key, for consumer reconcilers (e.g. Prowlarr sync, recyclarr).";
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
            };
            enableTorrent = lib.mkOption {
              type = lib.types.bool;
              default = true;
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
            };
            torrentDelay = lib.mkOption {
              type = lib.types.int;
              default = 0;
            };
            bypassIfHighestQuality = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };
        }
      );
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
        inherit displayName description;
        inherit (app) port;
        healthcheck.path = "/ping";
        forwardAuth.enable = lib.mkDefault cfg.auth.forwardAuth.active;
        access.allowedGroups = lib.mkDefault [ cfg.groups.admin ];
        integrations.homepage.icon = lib.mkDefault icon;
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

      runtimeSecrets.${apiKeySecret}.restartUnits = [
        "${name}.service"
        "${name}-configure.service"
      ];
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
      settings.server.port = app.port;
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
      wantedBy = [ "${name}.service" ];
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
