# Non-human principals: CI bots, machine accounts that authenticate to a share. Separate from
# `selfhost.users` because that schema requires a person's name and email and layers OIDC onto every
# entry, which a robot neither has nor needs. Apps extend this the same way they extend users.
{ config, lib, ... }:
let
  cfg = config.selfhost;
  unixAccounts = lib.filterAttrs (_: a: a.unixAccount.enable) cfg.serviceAccounts;
  unpinnedIds = lib.attrNames (
    lib.filterAttrs (_: a: a.unixAccount.uid == null || a.unixAccount.gid == null) unixAccounts
  );
  duplicates = lib.intersectLists (lib.attrNames cfg.users) (lib.attrNames cfg.serviceAccounts);
in
{
  options.selfhost.serviceAccounts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule [
        ./schemas/principal-storage-smb.nix
        {
          options = {
            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "What this account is for. Used as the gecos field when a POSIX user is created.";
            };

            unixAccount = {
              enable = lib.mkEnableOption "a POSIX account and matching primary group for this account on the host that declares it, so a service can resolve a session to a Unix identity";

              uid = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = "As in `users.users.<name>.uid`. Null picks a free one on activation; pin it where this account owns data that outlives the root filesystem, since the allocation is recorded only on root.";
              };

              gid = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = "As in `users.groups.<name>.gid`. Same reasoning as `uid`.";
              };
            };
          };
        }
      ]
    );
    default = { };
    description = ''
      Non-human principals, keyed by account name. Per-app config mirrors the registry at
      `serviceAccounts.<name>.services.<app>`, the same shape as `users.<name>.services.<app>`.

      `unixAccount.enable` additionally creates a POSIX account and its primary group on the host that
      declares it, for accounts that need a Unix identity (an SMB principal owning files, say). It is
      spelled the same on `users.<name>`, which gets a person-shaped account instead of a system one.
      Accounts that only exist inside an application leave it off.
    '';
  };

  config = {
    assertions = [
      {
        assertion = duplicates == [ ];
        message = "Names declared in both selfhost.users and selfhost.serviceAccounts: ${toString duplicates}. A principal belongs to one registry.";
      }
    ];

    warnings =
      lib.optional (unpinnedIds != [ ])
        "Service accounts with a POSIX account and no pinned uid or gid: ${toString unpinnedIds}. Read each back with `getent passwd` and `getent group`, then set `selfhost.serviceAccounts.<name>.unixAccount.uid` and `.gid`.";

    users.users = lib.mapAttrs (
      name: a:
      {
        isSystemUser = true;
        group = name;
        inherit (a.unixAccount) uid;
      }
      // lib.optionalAttrs (a.description != "") { inherit (a) description; }
    ) unixAccounts;

    users.groups = lib.mapAttrs (_: a: { inherit (a.unixAccount) gid; }) unixAccounts;
  };
}
