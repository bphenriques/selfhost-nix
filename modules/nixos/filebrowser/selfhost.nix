# Selfhost integration: maps selfhost.users opt-ins into services.filebrowser-multiuser and assembles
# each user's scope from their SMB `storage` grants (service-namespace binds; names stay private).
{ config, lib, ... }:
let
  cfg = config.services.filebrowser-multiuser;
  smb = config.selfhost.storage.smb.mounts;
  fbRoot = config.services.filebrowser.settings.root;
  enabledUsers = lib.filterAttrs (_: u: u.services.filebrowser.enable) config.selfhost.users;
  grants = lib.concatLists (
    lib.mapAttrsToList (
      user: u:
      lib.mapAttrsToList (mount: perm: {
        inherit user mount;
        readOnly = perm == "ro";
      }) u.services.filebrowser.storage
    ) enabledUsers
  );
  bindSpec = g: "${smb.${g.mount}.localMount}:${fbRoot}/${g.user}/${g.mount}";
in
{
  config = lib.mkIf (cfg.enable && cfg.enableSelfhostIntegration) {
    warnings = lib.mapAttrsToList (
      name: _: "selfhost.users.${name}.services.filebrowser is enabled with no storage grants — empty FileBrowser."
    ) (lib.filterAttrs (_: u: u.services.filebrowser.storage == { }) enabledUsers);

    services.filebrowser-multiuser.users = lib.mapAttrs (user: u: {
      scope = "/${user}";
      readOnly = !(lib.elem "rw" (lib.attrValues u.services.filebrowser.storage));
      inherit (u.services.filebrowser) admin;
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
  };
}
