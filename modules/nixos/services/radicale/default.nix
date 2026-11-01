# Radicale app: the web UI sits behind forwardAuth, and dav.<domain> serves sync clients on Radicale's htpasswd.
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

  # The consumer may relocate storage, so backup and the reconciler read the effective value.
  dataDir = config.services.radicale.settings.storage.filesystem_folder;
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
  imports = [ ./user.nix ];

  options.selfhost.apps.radicale = {
    enable = lib.mkEnableOption "the first-party Radicale app (CalDAV/CardDAV server)";
  };

  config = lib.mkIf app.enable {
    selfhost.services.radicale = {
      displayName = lib.mkDefault "Radicale";
      meta.homepage = lib.mkDefault "https://radicale.org";
      meta.description = lib.mkDefault "CalDAV & CardDAV";
      meta.category = lib.mkDefault "productivity";
      port = lib.mkDefault 5232;
      subdomain = lib.mkDefault "radicale";
      access.allowedGroups = lib.mkDefault [ config.selfhost.groups.admin ];
      # Only the gateway can enforce allowedGroups, so the web route rides it.
      access.model = "forwardAuth";
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

    # Sync clients use Radicale's htpasswd, so this route needs no gateway and stays up without one.
    selfhost.services.radicale-dav = {
      displayName = lib.mkDefault "Radicale (DAV)";
      meta.description = lib.mkDefault "CalDAV & CardDAV sync endpoint";
      backend = "radicale";
      subdomain = lib.mkDefault "dav";
      access.model = "native"; # htpasswd, which is what DAV clients can actually do
      integrations.homepage.enable = false; # a sync endpoint, not a destination
      # .well-known redirects (RFC 6764) let DAVx5 and others auto-discover the server.
      traefik.middlewares.radicale-wellknown.redirectRegex = {
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
        storage.filesystem_folder = lib.mkDefault "/var/lib/radicale/collections";
      };
    };
    warnings = lib.optional (
      enabledUsernames == [ ]
    ) "selfhost.apps.radicale: no selfhost.users have services.radicale.enable — Radicale will have no accounts.";

    # StateDirectory only appears when radicale starts, but the configure unit before it writes the htpasswd there.
    systemd.tmpfiles.rules = [ "d /var/lib/radicale 0750 radicale radicale -" ];

    selfhost.runtimeSecrets = lib.listToAttrs (
      map (uname: {
        name = "radicale-password-${uname}";
        value = {
          bytes = 12; # a person types this into a calendar app
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
        # No filesystem sandbox: the htpasswd lives beside state that upstream may relocate.
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      environment.RADICALE_PROVISION_FILE = configFile;
      script = lib.getExe radicale-configure;
    };
  };
}
