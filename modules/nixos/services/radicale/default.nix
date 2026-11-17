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

  enabledUsers = lib.filterAttrs (_: u: u.services.radicale.enable) config.selfhost.users;
  enabledUsernames = builtins.attrNames enabledUsers;
  serviceAccounts = lib.filterAttrs (_: a: a.services.radicale.enable) config.selfhost.serviceAccounts;
  ungranted = lib.subtractLists (lib.attrNames serviceAccounts) (
    lib.concatMap (u: u.services.radicale.access.serviceAccounts) (lib.attrValues enabledUsers)
  );

  # The consumer may relocate storage, so backup and the reconciler read the effective value.
  dataDir = config.services.radicale.settings.storage.filesystem_folder;
  htpasswdFile = "/var/lib/radicale/users";

  configFile = pkgs.writeText "radicale-configure.json" (
    builtins.toJSON {
      inherit htpasswdFile;
      users =
        lib.genAttrs enabledUsernames (uname: {
          passwordFile = config.selfhost.runtimeSecrets."radicale-password-${uname}".path;
        })
        // lib.mapAttrs (_: a: { inherit (a.services.radicale) passwordFile; }) serviceAccounts;
    }
  );

  anyOf = names: "(${lib.concatMapStringsSep "|" lib.escapeRegex names})";

  # Radicale's owner_only for people. A service account reaches only what an owner granted, and never deletes,
  # replaces, shares or renames a collection there (`d`, `o`, `t` and `m`, `l`).
  rights =
    lib.optionalAttrs (enabledUsernames != [ ]) {
      root = {
        user = anyOf (enabledUsernames ++ lib.attrNames serviceAccounts);
        collection = "";
        permissions = "R";
      };
      owner-principal = {
        user = anyOf enabledUsernames;
        collection = "{user}";
        permissions = "RW";
      };
      owner-collections = {
        user = anyOf enabledUsernames;
        collection = "{user}/[^/]+";
        permissions = "rw";
      };
    }
    # Radicale creates the login's own principal on its first request, or warns on every one. Nothing grants it collections.
    // lib.optionalAttrs (serviceAccounts != { }) {
      service-account-principal = {
        user = anyOf (lib.attrNames serviceAccounts);
        collection = "{user}";
        permissions = "RW";
      };
    }
    // lib.concatMapAttrs (
      owner: u:
      lib.optionalAttrs (u.services.radicale.access.serviceAccounts != [ ]) {
        "grant-${owner}-principal" = {
          user = anyOf u.services.radicale.access.serviceAccounts;
          collection = lib.escapeRegex owner;
          permissions = "R";
        };
        "grant-${owner}-collections" = {
          user = anyOf u.services.radicale.access.serviceAccounts;
          collection = "${lib.escapeRegex owner}/[^/]+";
          permissions = "rwdotml";
        };
      }
    ) enabledUsers;

  git = lib.getExe pkgs.git;

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
  imports = [
    ./user.nix
    ./service-account.nix
  ];

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
        # Every change is a commit in the collections folder, named after its login, so any item can be restored.
        storage.hook = lib.mkDefault "[ -d .git ] || { ${git} init -q && printf '.Radicale.cache\\n.Radicale.lock\\n.Radicale.tmp-*\\n' > .git/info/exclude; }; ${git} add -A && (${git} diff --cached --quiet || ${git} -c user.name=Radicale -c user.email=radicale@localhost commit -q -m \"Changes by %(user)s\")";
      };
      inherit rights;
    };
    warnings = lib.optional (
      enabledUsernames == [ ]
    ) "selfhost.apps.radicale: no selfhost.users have services.radicale.enable — Radicale will have no accounts.";
    assertions = [
      {
        assertion = ungranted == [ ];
        message = "selfhost.users.*.services.radicale.access.serviceAccounts names accounts without a Radicale login: ${toString ungranted}. Set `services.radicale.enable` on their selfhost.serviceAccounts entry.";
      }
    ];

    # StateDirectory only appears when radicale starts, but the configure unit before it writes the htpasswd there.
    systemd.tmpfiles.rules = [ "d /var/lib/radicale 0750 radicale radicale -" ];

    selfhost.runtimeSecrets =
      lib.listToAttrs (
        map (uname: {
          name = "radicale-password-${uname}";
          value = {
            bytes = 12; # a person types this into a calendar app
            restartUnits = [ "radicale-configure.service" ];
          };
        }) enabledUsernames
      )
      //
        lib.mapAttrs'
          (
            name: _:
            lib.nameValuePair "radicale-password-${name}" {
              bytes = 32; # only ever copied into the client's own secrets
              restartUnits = [ "radicale-configure.service" ];
            }
          )
          (
            lib.filterAttrs (
              name: a: a.services.radicale.passwordFile == "${config.selfhost.runtimeSecretsDir}/radicale-password-${name}"
            ) serviceAccounts
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
