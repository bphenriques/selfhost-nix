# First-party CouchDB app. `native` access: it authenticates HTTP clients itself, which is the only
# model a replicating client can speak. Accounts and their databases derive from selfhost.users.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.couchdb;
  serviceCfg = config.selfhost.services.couchdb;

  enabledUsers = lib.filterAttrs (_: u: u.services.couchdb.enable) config.selfhost.users;

  # Local address, not the public route: the reconciler talks to CouchDB before any gateway exists.
  localUrl = "http://${config.services.couchdb.bindAddress}:${toString config.services.couchdb.port}";

  baseConfigFile = pkgs.writeText "couchdb-base.ini" (
    lib.generators.toINI { } {
      couchdb.single_node = true;
      chttpd = {
        require_valid_user = true;
        require_valid_user_except_for_up = true; # keeps healthcheck.path answerable
      };
      chttpd_auth.require_valid_user = true;
      chttpd_auth_lockout.mode = "warn";
      cluster.n = 1; # a replica count above the node count is only an error in the log
      httpd."WWW-Authenticate" = ''Basic realm="couchdb"'';
    }
  );

  configFile = pkgs.writeText "couchdb-configure.json" (
    builtins.toJSON {
      users = lib.mapAttrsToList (uname: _: {
        name = uname;
        passwordFile = config.selfhost.runtimeSecrets."couchdb-password-${uname}".path;
      }) enabledUsers;

      databases = lib.concatLists (
        lib.mapAttrsToList (
          uname: u:
          map (db: {
            name = db;
            owner = uname;
          }) u.services.couchdb.databases
        ) enabledUsers
      );
    }
  );

  couchdb-configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "couchdb-configure";
    runtimeInputs = [ pkgs.coreutils ];
    script = ./configure.nu;
  };
in
{
  imports = [ ./user.nix ];

  options.selfhost.apps.couchdb = {
    enable = lib.mkEnableOption "the first-party CouchDB app (document database)";
  };

  config = lib.mkIf app.enable {
    selfhost.services.couchdb = {
      displayName = lib.mkDefault "CouchDB";
      meta.homepage = lib.mkDefault "https://couchdb.apache.org";
      meta.description = lib.mkDefault "Document database";
      port = lib.mkDefault 5984;
      subdomain = lib.mkDefault "couchdb";
      access.model = "native"; # HTTP basic auth, which is what a replicating client can do
      healthcheck.path = "/_up";
      integrations.homepage.enable = false; # a sync backend, not a destination
    };

    # Plaintext in a tmpfs template, never the store. CouchDB rewrites it as a hash into its own
    # writable local.ini on first start, and that later file is what wins from then on.
    selfhost.runtimeSecrets = {
      couchdb-admin-password.restartUnits = [
        "couchdb.service"
        "couchdb-configure.service"
      ];
    }
    // lib.mapAttrs' (
      uname: _:
      lib.nameValuePair "couchdb-password-${uname}" {
        bytes = 12; # typed into a sync client by hand
        restartUnits = [ "couchdb-configure.service" ];
      }
    ) enabledUsers;

    selfhost.runtimeTemplates."couchdb-admin.ini" = {
      content = ''
        [admins]
        ${config.services.couchdb.adminUser} = ${config.selfhost.runtimePlaceholder.couchdb-admin-password}
      '';
      owner = config.services.couchdb.user;
      restartUnits = [ "couchdb.service" ];
    };

    services.couchdb = {
      enable = true;
      port = lib.mkDefault serviceCfg.port;
      # Not extraConfig: that option is types.attrs, so a consumer defining `chttpd` at all replaces
      # this whole section rather than merging into it, and require_valid_user disappears silently.
      # CouchDB merges its ini chain per key, and these files sit after the one extraConfig renders,
      # so the invariants hold whatever the consumer sets there.
      extraConfigFiles = [
        baseConfigFile
        config.selfhost.runtimeTemplates."couchdb-admin.ini".path
      ];
    };
    warnings = lib.optional (
      enabledUsers == { }
    ) "selfhost.apps.couchdb: no selfhost.users have services.couchdb.enable — CouchDB will have no accounts.";

    systemd.services.couchdb-configure = {
      description = "Reconcile CouchDB users and databases from selfhost users";
      wantedBy = [ "couchdb.service" ];
      after = [ "couchdb.service" ];
      requires = [ "couchdb.service" ];
      partOf = [ "couchdb.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        Restart = "on-failure";
        RestartSec = 10;
        UMask = "0077";
        # No filesystem sandbox: it writes nothing, but reads secrets under a dir the consumer owns.
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      environment = {
        COUCHDB_URL = localUrl;
        COUCHDB_ADMIN_USER = config.services.couchdb.adminUser;
        COUCHDB_ADMIN_PASS_FILE = config.selfhost.runtimeSecrets.couchdb-admin-password.path;
        COUCHDB_PROVISION_FILE = configFile;
      };
      script = lib.getExe couchdb-configure;
    };
  };
}
