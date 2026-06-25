# Per-user proxy-auth access management on top of `services.filebrowser` (model: docs filebrowser chapter).
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.filebrowser-multiuser;
  fb = config.services.filebrowser.settings;
  fbPkg = config.services.filebrowser.package; # seed with the same filebrowser the service serves

  configureScript = pkgs.runCommandLocal "filebrowser-configure.nu" { } ''
    ${lib.getExe pkgs.nushell} --no-config-file --commands 'if not (nu-check "${./configure.nu}") { exit 1 }'
    cp ${./configure.nu} $out
  '';
  filebrowser-configure = pkgs.writeShellApplication {
    name = "filebrowser-configure";
    runtimeInputs = [
      pkgs.nushell
      fbPkg
    ];
    text = ''exec nu ${configureScript} "$@"'';
  };

  permKeys = [
    "create"
    "delete"
    "rename"
    "modify"
    "execute"
    "share"
    "download"
  ];
  writeKeys = [
    "create"
    "delete"
    "rename"
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
  userList = lib.mapAttrsToList (name: u: u // { inherit name; }) cfg.users;

  # Scopes must resolve to real directories the host arranged; fail loudly rather than serve empty.
  scopeCheck = pkgs.writeShellScript "filebrowser-scope-check" ''
    for s in ${lib.escapeShellArgs (lib.unique (map (u: u.scope) userList))}; do
      [ -d "${fb.root}$s" ] || { echo "filebrowser-multiuser: scope '$s' has no directory under ${fb.root}" >&2; exit 1; }
    done
  '';

  # Upstream settings + the access model, in separate keys so they never collide.
  fbConfig = pkgs.writeText "filebrowser.json" (
    builtins.toJSON {
      settings = fb;
      access = {
        inherit (cfg) authHeader;
        defaults = {
          scope = cfg.unlistedScope;
          permissions = cfg.unlistedPermissions;
        };
        users = map (u: {
          username = u.name;
          inherit (u) scope admin permissions;
        }) userList;
      };
    }
  );
in
{
  options.services.filebrowser-multiuser = {
    enable = lib.mkEnableOption "per-user access management for services.filebrowser";
    enableSelfhostIntegration = lib.mkEnableOption "mapping selfhost.users into this module + registering behind selfhost forwardAuth";
    authHeader = lib.mkOption {
      type = lib.types.str;
      default = "Remote-User";
      description = "HTTP header the edge sets to the authenticated username (and must strip from client input).";
    };
    unlistedScope = lib.mkOption {
      type = lib.types.str;
      description = "Scope for an authenticated user not in `users` (FileBrowser auto-creates them); point at an empty dir for no access.";
    };
    unlistedPermissions = lib.mkOption {
      type = permsType true;
      default = { };
      description = "Permissions for those auto-created users; read-only unless set.";
    };
    users = lib.mkOption {
      default = { };
      description = "Proxy-auth users and what each may access.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { config, ... }: {
            options = {
              scope = lib.mkOption {
                type = lib.types.str;
                description = "Path under the FileBrowser root (arranged by the host).";
              };
              admin = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Grant FileBrowser admin.";
              };
              readOnly = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Baseline read-only; set false for read-write, or override individual `permissions` (e.g. readOnly + create = upload-only).";
              };
              permissions = lib.mkOption {
                default = { };
                description = "Per-permission overrides; each defaults from `readOnly` (writes = !readOnly, download = true, execute/share = false).";
                type = permsType config.readOnly;
              };
            };
          }
        )
      );
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.services.filebrowser.enable;
        message = "services.filebrowser-multiuser needs services.filebrowser.enable.";
      }
      {
        assertion = !cfg.enableSelfhostIntegration || (options ? selfhost);
        message = "services.filebrowser-multiuser.enableSelfhostIntegration requires the selfhost stack (and its adapter); it has no effect on its own.";
      }
      {
        assertion = !(fb ? users || fb ? defaults);
        message = "services.filebrowser-multiuser manages services.filebrowser.settings.{users,defaults}; declare them via services.filebrowser-multiuser instead.";
      }
      {
        assertion = !(fb.createUserDir or false);
        message = "services.filebrowser-multiuser uses explicit host-arranged scopes; services.filebrowser.settings.createUserDir must stay false (it mkdir's the scope as an absolute path).";
      }
    ];

    systemd.services.filebrowser.serviceConfig.ExecStartPre = [ "${scopeCheck}" ];

    # Rebuilt on config change (removed users drop with it).
    systemd.services.filebrowser-configure = {
      description = "Seed FileBrowser proxy-auth users";
      requiredBy = [ "filebrowser.service" ];
      before = [ "filebrowser.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      unitConfig.RequiresMountsFor = [ fb.root ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = config.services.filebrowser.user;
        Group = config.services.filebrowser.group;
      };
      environment = {
        FILEBROWSER_CONFIG_FILE = fbConfig;
        FILEBROWSER_DB = fb.database;
        FILEBROWSER_ROOT = fb.root;
      };
      script = lib.getExe filebrowser-configure;
    };
  };
}
