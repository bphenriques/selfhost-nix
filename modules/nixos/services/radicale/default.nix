# First-party Radicale app: a CalDAV/CardDAV server. The web UI sits behind forwardAuth; a separate
# dav.<domain> route serves sync clients on Radicale's own htpasswd auth (RFC 6764 .well-known
# redirects for auto-discovery). enableSelfhostIntegration derives that htpasswd from selfhost.users.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.radicale;
  serviceCfg = config.selfhost.services.radicale;

  enabledUsernames = builtins.attrNames (lib.filterAttrs (_: u: u.services.radicale.enable) config.selfhost.users);

  dataDir = "/var/lib/radicale/collections";
  htpasswdFile = "/var/lib/radicale/users";

  configFile = pkgs.writeText "radicale-configure.json" (
    builtins.toJSON {
      inherit htpasswdFile;
      users = lib.listToAttrs (
        map (uname: {
          name = uname;
          value = {
            passwordFile = config.selfhost.runtimeSecrets."radicale-password-${uname}".path;
          };
        }) enabledUsernames
      );
    }
  );

  radicale-configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "radicale-configure";
    runtimeInputs = [
      pkgs.apacheHttpd
      pkgs.coreutils
    ];
    script = ./configure.nu;
  };
in
{
  options.selfhost = {
    apps.radicale = {
      enable = lib.mkEnableOption "the first-party Radicale app (CalDAV/CardDAV server)";
      enableSelfhostIntegration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Derive Radicale's htpasswd users from selfhost.users grants. Turn off to run Radicale but manage its htpasswd file yourself.";
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.services.radicale.enable = lib.mkEnableOption "Radicale CalDAV/CardDAV access for this user";
        }
      );
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (config.selfhost.enable && app.enable) {
      selfhost.services.radicale = {
        displayName = lib.mkDefault "Radicale";
        description = lib.mkDefault "CalDAV & CardDAV";
        port = lib.mkDefault 5232;
        subdomain = lib.mkDefault "radicale";
        access.allowedGroups = lib.mkDefault [ config.selfhost.groups.admin ];
        forwardAuth.enable = lib.mkDefault config.selfhost.auth.forwardAuth.enabled; # follows the gateway being active
        integrations.homepage.group = lib.mkDefault "Admin";
        healthcheck.path = "/.web/";
        healthcheck.probeModule = "http_any"; # Radicale requires htpasswd auth on all endpoints; 401 confirms it is up

        backup = {
          package = pkgs.writeShellApplication {
            name = "backup-radicale";
            text = ''
              export RADICALE_DATA="${dataDir}"
              # shellcheck disable=SC1091
              source ${./backup.sh}
            '';
          };
          after = [ "radicale.service" ];
        };
      };

      # CalDAV/CardDAV sync endpoint without forwardAuth — clients use Radicale's own htpasswd auth.
      # .well-known redirects (RFC 6764) let DAVx5 and others auto-discover the server.
      services.traefik.dynamicConfigOptions.http = {
        routers.radicale-dav = {
          rule = "Host(`dav.${config.selfhost.domain}`)";
          entryPoints = [ "websecure" ];
          service = "radicale-svc";
          middlewares = [ "radicale-wellknown" ];
        };
        middlewares.radicale-wellknown.redirectRegex = {
          regex = "^(https?://[^/]+)/\\.well-known/(caldav|carddav)/?$"; # Traefik matches the full URL, not the path
          replacement = "\${1}/";
          permanent = false;
        };
      };

      services.radicale = {
        enable = true;
        settings = {
          auth = {
            type = "htpasswd";
            htpasswd_filename = htpasswdFile;
            htpasswd_encryption = "bcrypt";
          };
          server.hosts = [ "127.0.0.1:${toString serviceCfg.port}" ];
          storage.filesystem_folder = dataDir;
        };
      };
    })

    # Selfhost integration: htpasswd derived from selfhost.users (off ⇒ manage the htpasswd file yourself).
    (lib.mkIf (config.selfhost.enable && app.enable && app.enableSelfhostIntegration) {
      warnings =
        lib.optional (enabledUsernames == [ ])
          "selfhost.apps.radicale: enableSelfhostIntegration is on but no selfhost.users have services.radicale.enable — Radicale will have no accounts.";

      selfhost.runtimeSecrets = lib.listToAttrs (
        map (uname: {
          name = "radicale-password-${uname}";
          value = {
            bytes = 24;
            regenerateIfMissing = false;
            restartUnits = [ "radicale-configure.service" ];
          };
        }) enabledUsernames
      );

      systemd.services.radicale-configure = {
        description = "Generate Radicale htpasswd from selfhost users";
        requiredBy = [ "radicale.service" ];
        before = [ "radicale.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = 600;
          Restart = "on-failure";
          RestartSec = 10;
          UMask = "0027";
        };
        startLimitIntervalSec = 300;
        startLimitBurst = 3;
        environment.RADICALE_PROVISION_FILE = configFile;
        script = lib.getExe radicale-configure;
      };
    })
  ];
}
