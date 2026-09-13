# Standalone FileBrowser Quantum: serves one source and reconciles per-user access over its API.
# See the FileBrowser Quantum docs chapter for the model.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.filebrowser-quantum;
  sourceName = "files"; # the API addresses scopes by the source's display name
  format = pkgs.formats.yaml { };

  permKeys = [
    "api"
    "create"
    "delete"
    "download"
    "modify"
    "realtime"
    "share"
  ];
  writeKeys = [
    "create"
    "delete"
    "modify"
  ];
  # Writes follow !readOnly, download stays on, the rest off.
  permDefaults = readOnly: lib.genAttrs permKeys (k: if lib.elem k writeKeys then !readOnly else k == "download");
  permsType =
    readOnly:
    lib.types.submodule {
      options = lib.mapAttrs (
        k: d:
        lib.mkOption {
          type = lib.types.bool;
          default = d;
          description = "FileBrowser `${k}` permission.";
        }
      ) (permDefaults readOnly);
    };

  userList = lib.mapAttrsToList (name: u: {
    username = name;
    inherit (u) scope admin permissions;
  }) cfg.users;

  reconcileFile = pkgs.writeText "filebrowser-quantum-users.json" (
    builtins.toJSON {
      inherit sourceName;
      inherit (cfg) loginMethod;
      users = userList;
    }
  );

  configFile = format.generate "filebrowser-quantum.yaml" cfg.settings;

  # Scopes must resolve to real directories the host arranged; fail loudly rather than serve empty.
  scopeCheck = pkgs.writeShellScript "filebrowser-quantum-scope-check" ''
    for s in ${lib.escapeShellArgs (lib.unique ([ cfg.unlistedScope ] ++ map (u: u.scope) (lib.attrValues cfg.users)))}; do
      [ -d "${cfg.source.path}$s" ] || { echo "filebrowser-quantum: scope '$s' has no directory under ${cfg.source.path}" >&2; exit 1; }
    done
  '';

  # Quantum takes secrets from the environment only, so the rendered config carries none.
  start = pkgs.writeShellScript "filebrowser-quantum-start" ''
    export FILEBROWSER_ADMIN_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/admin-password")"
    exec ${lib.getExe cfg.package} -c ${configFile}
  '';

  # Beyond the repo baseline: this unit serves the host's most sensitive tree, and behind a public
  # edge it is the reachable one. It needs no capabilities and only ordinary sockets. No filesystem
  # sandbox: it writes where the consumer points it.
  hardened = {
    CapabilityBoundingSet = "";
    AmbientCapabilities = "";
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
    RestrictNamespaces = true;
    LockPersonality = true;
    RestrictRealtime = true;
    PrivateDevices = true;
    ProtectHostname = true;
    ProtectClock = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    UMask = "0077"; # the database and cache; uploads are chmod'd by Quantum, see createFilePermission
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
  };

  configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "filebrowser-quantum-configure";
    script = ./configure.nu;
  };
in
{
  options.services.filebrowser-quantum = {
    enable = lib.mkEnableOption "FileBrowser Quantum with per-user access management";

    package = lib.mkPackageOption pkgs "filebrowser-quantum" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "filebrowser-quantum";
      description = "User account under which FileBrowser Quantum runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "filebrowser-quantum";
      description = "Group under which FileBrowser Quantum runs.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/filebrowser-quantum";
      description = "Directory holding the database and cache.";
    };

    source = {
      path = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.stateDir}/root";
        defaultText = lib.literalMD "`<stateDir>/root`";
        description = "Filesystem root served by this instance; every scope is a path under it.";
      };
      rules = lib.mkOption {
        type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
        default = [ ];
        example = lib.literalExpression ''[ { folderPath = "/lost+found"; } ]'';
        description = "Indexing rules for the source; a filesystem root needs one for `lost+found`, which the indexer cannot read.";
      };
    };

    adminUsername = lib.mkOption {
      type = lib.types.str;
      default = "filebrowser-admin";
      description = "Account the reconciler drives the API as. Created from `adminPasswordFile` as a password login, which is what makes the proxy header unable to assume it.";
    };

    adminPasswordFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to a file holding the admin password; bootstraps the admin account and authenticates the reconciler.";
    };

    loginMethod = lib.mkOption {
      type = lib.types.enum [
        "proxy"
        "oidc"
      ];
      default = "proxy";
      description = "How declared users authenticate; the reconciler creates accounts of this kind and reconciles only those.";
    };

    authHeader = lib.mkOption {
      type = lib.types.str;
      default = "Remote-User";
      description = "HTTP header the edge sets to the authenticated username (and must strip from client input).";
    };

    unlistedScope = lib.mkOption {
      type = lib.types.str;
      description = "Scope for an authenticated user not in `users` (FileBrowser auto-creates them); point at an empty dir for no access.";
    };

    users = lib.mkOption {
      default = { };
      description = "Declared users and what each may access; they log in by `loginMethod`.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }:
          {
            options = {
              scope = lib.mkOption {
                type = lib.types.str;
                description = "Path under the source root (arranged by the host).";
              };
              admin = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Grant FileBrowser admin.";
              };
              readOnly = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Baseline read-only; set false for read-write, or override individual `permissions`.";
              };
              permissions = lib.mkOption {
                default = { };
                description = "Per-permission overrides; each defaults from `readOnly` (writes = !readOnly, download = true, the rest off).";
                type = permsType config.readOnly;
              };
            };
          }
        )
      );
    };

    settings = lib.mkOption {
      inherit (format) type;
      default = { };
      description = "FileBrowser Quantum configuration, rendered to its config file. Holds no secrets: those come from the environment.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = !(lib.hasAttr cfg.adminUsername cfg.users);
        message = "services.filebrowser-quantum.adminUsername collides with a declared user: FileBrowser would grant them admin.";
      }
    ];

    services.filebrowser-quantum.settings = {
      server = {
        # Upstream binds 0.0.0.0; this service is always meant to sit behind an edge.
        listen = lib.mkDefault "127.0.0.1";
        port = lib.mkDefault 8085;
        database = lib.mkDefault "${cfg.stateDir}/database.db";
        cacheDir = lib.mkDefault "${cfg.stateDir}/cache";
        # WebDAV authenticates with a JWT in the password field, so it cannot coexist with an edge
        # that owns the Authorization header. Enable it only where nothing else claims that header.
        disableWebDAV = lib.mkDefault true;
        disableUpdateCheck = lib.mkDefault true;
        # Quantum chmods new files after creating them, so UMask cannot reach them. Group-readable
        # keeps share-backed setups working; world-readable is not a default worth shipping.
        filesystem = {
          createFilePermission = lib.mkDefault "640";
          createDirectoryPermission = lib.mkDefault "750";
        };
        sources = [
          {
            inherit (cfg.source) path;
            name = sourceName;
            config = {
              # The unlisted scope is a property of the source, not of userDefaults.
              defaultUserScope = cfg.unlistedScope;
              defaultEnabled = true;
              createUserDir = false;
              inherit (cfg.source) rules;
            };
          }
        ];
      };
      auth = {
        inherit (cfg) adminUsername;
        methods = {
          password.enabled = lib.mkDefault true;
          proxy = {
            enabled = lib.mkDefault (cfg.loginMethod == "proxy");
            header = cfg.authHeader;
          };
          oidc.enabled = lib.mkDefault (cfg.loginMethod == "oidc");
        };
      };
      # Auto-created users (proxy and OIDC alike) land here; override via settings if ever needed.
      userDefaults.account.permissions = lib.mkDefault (permDefaults true);
    };

    users.users = lib.mkIf (cfg.user == "filebrowser-quantum") {
      filebrowser-quantum = {
        description = "FileBrowser Quantum daemon user";
        inherit (cfg) group;
        isSystemUser = true;
      };
    };
    users.groups = lib.mkIf (cfg.group == "filebrowser-quantum") { filebrowser-quantum = { }; };

    systemd.tmpfiles.settings.filebrowser-quantum = {
      "${cfg.stateDir}".d = {
        inherit (cfg) user group;
        mode = "0750";
      };
    }
    # tmpfiles refuses to descend from our state dir into a root-owned one, so the default root has
    # to be declared rather than left to parent auto-creation. A consumer-chosen path stays theirs.
    // lib.optionalAttrs (cfg.source.path == "${cfg.stateDir}/root") {
      "${cfg.source.path}".d = {
        inherit (cfg) user group;
        mode = "0750";
      };
    };

    systemd.services.filebrowser-quantum = {
      description = "FileBrowser Quantum";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      unitConfig.RequiresMountsFor = [
        cfg.source.path
        cfg.stateDir
      ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStartPre = [ "${scopeCheck}" ];
        ExecStart = "${start}";
        LoadCredential = [ "admin-password:${cfg.adminPasswordFile}" ];
        Restart = "on-failure";
        RestartSec = 5;
      }
      // hardened;
    };

    # Reconciles against the running server: the CLI only creates password accounts, so users of any
    # other login method cannot be seeded offline. Users dropped from the config are deleted.
    systemd.services.filebrowser-quantum-configure = {
      description = "Reconcile FileBrowser Quantum users";
      wantedBy = [ "filebrowser-quantum.service" ];
      after = [ "filebrowser-quantum.service" ];
      requires = [ "filebrowser-quantum.service" ];
      partOf = [ "filebrowser-quantum.service" ];
      restartTriggers = [
        reconcileFile
        configure
      ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 300;
        User = cfg.user;
        Group = cfg.group;
        LoadCredential = [ "admin-password:${cfg.adminPasswordFile}" ];
        Restart = "on-failure";
        RestartSec = 10;
      }
      // hardened;
      environment = {
        FILEBROWSER_URL = "http://${cfg.settings.server.listen}:${toString cfg.settings.server.port}";
        FILEBROWSER_CONFIG_FILE = "${reconcileFile}";
        FILEBROWSER_ADMIN_USERNAME = cfg.adminUsername;
      };
      script = lib.getExe configure;
    };
  };
}
