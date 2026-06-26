# First-party FileBrowser app: enables the multiuser base and (optionally) wires it into the
# selfhost framework — deriving users + per-user SMB binds from selfhost.users grants.
{ config, lib, ... }:
let
  app = config.selfhost.apps.filebrowser;
  smb = config.selfhost.storage.smb.mounts;
  fbRoot = config.services.filebrowser.settings.root;
  enabledUsers = lib.filterAttrs (_: u: u.apps.filebrowser.enable) config.selfhost.users;
  grants = lib.concatLists (
    lib.mapAttrsToList (
      user: u:
      lib.mapAttrsToList (mount: perm: {
        inherit user mount;
        readOnly = perm == "ro";
      }) u.apps.filebrowser.storage
    ) enabledUsers
  );
  bindSpec = g: "${smb.${g.mount}.localMount}:${fbRoot}/${g.user}/${g.mount}";
in
{
  options.selfhost = {
    apps.filebrowser = {
      enable = lib.mkEnableOption "the first-party FileBrowser app (per-user proxy-auth file sharing)";
      enableSelfhostIntegration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Derive FileBrowser users and per-user SMB binds from selfhost.users grants and register behind selfhost forwardAuth. Turn off to run the app but wire users, storage and auth yourself.";
      };
    };

    # The app owns its own per-user surface (kept out of core's user schema).
    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.apps.filebrowser = {
            enable = lib.mkEnableOption "a FileBrowser entry for this user (access is gated by the service auth, not this flag)";
            storage = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.enum [
                  "ro"
                  "rw"
                ]
              );
              default = { };
              description = "selfhost SMB mounts this user may access, keyed by permission; unioned into their scope (read-write iff any is `rw`).";
            };
            admin = lib.mkEnableOption "FileBrowser admin";
          };
        }
      );
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (config.selfhost.enable && app.enable) {
      services.filebrowser-multiuser.enable = true;
      selfhost.services.filebrowser = {
        displayName = lib.mkDefault "File Browser";
        description = lib.mkDefault "File Browser";
        port = lib.mkDefault 8085;
      };
    })

    (lib.mkIf (config.selfhost.enable && app.enable && app.enableSelfhostIntegration) {
      warnings = lib.mapAttrsToList (
        name: _: "selfhost.users.${name}.apps.filebrowser is enabled with no storage grants — empty FileBrowser."
      ) (lib.filterAttrs (_: u: u.apps.filebrowser.storage == { }) enabledUsers);

      services.filebrowser-multiuser.users = lib.mapAttrs (user: u: {
        scope = "/${user}";
        readOnly = !(lib.elem "rw" (lib.attrValues u.apps.filebrowser.storage));
        inherit (u.apps.filebrowser) admin;
      }) enabledUsers;

      selfhost.services.filebrowser = {
        forwardAuth.enable = true;
        storage.smb = lib.unique (map (g: g.mount) grants);
      };

      # ro grants get a ro bind that can't be bypassed (same namespace, never re-bound).
      systemd.services.filebrowser.serviceConfig = {
        BindPaths = map bindSpec (lib.filter (g: !g.readOnly) grants);
        BindReadOnlyPaths = map bindSpec (lib.filter (g: g.readOnly) grants);
      };
    })
  ];
}
