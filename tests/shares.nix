# storage.shares.smb (eval-only): samba config, share groups and the guards are generated from the two
# principal registries. The VM test covers the running server; this covers what refuses to build.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  password = "/run/secrets/smb-password";

  base = {
    users.ada.storage.smb = {
      enable = true;
      passwordFile = password;
    };
    serviceAccounts.machine-backup = {
      systemUser.enable = true;
      storage.smb = {
        enable = true;
        passwordFile = password;
      };
    };
    storage.shares.smb = {
      enable = true;
      openFirewall = true;
      shares.media = {
        path = "/srv/storage/media";
        owner = "ada";
        gid = 990;
        directories = [ "movies" ];
        access = {
          ada = "rw";
          machine-backup = "ro";
        };
      };
    };
  };

  # `common`'s admin is the only declared user, so give ada a Unix identity the same way a host would.
  unixUsers = {
    users.users.ada = {
      isNormalUser = true;
      uid = 4000;
    };
  };

  cfg = evalConfig {
    selfhost = base;
    imports = [ unixUsers ];
  };

  media = cfg.services.samba.settings.media;
  passwords = cfg.systemd.services.selfhost-smb-passwords;
  permissions = cfg.systemd.services.selfhost-smb-permissions;

  fires =
    module: infix:
    let
      c = evalConfig module;
    in
    lib.any (a: !a.assertion && lib.hasInfix infix a.message) c.assertions;

  ungranted = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.media.access.stranger = "rw";
    };
    imports = [ unixUsers ];
  } "no SMB account";

  noUnixUser = fires { selfhost = base; } "need a Unix user";

  noPassword = fires {
    selfhost = lib.recursiveUpdate base { users.ada.storage.smb.passwordFile = null; };
    imports = [ unixUsers ];
  } "no `storage.smb.passwordFile`";

  bothRegistries = fires {
    selfhost = lib.recursiveUpdate base { serviceAccounts.ada.description = "robot"; };
    imports = [ unixUsers ];
  } "declared in both";

  emptyAccess = fires {
    selfhost = lib.recursiveUpdate base { storage.shares.smb.shares.open.path = "/srv/storage/open"; };
    imports = [ unixUsers ];
  } "no `access` entries";

  reservedName = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.global = {
        path = "/srv/g";
        access.ada = "rw";
      };
    };
    imports = [ unixUsers ];
  } "cannot be named";

  unpinned =
    (evalConfig {
      selfhost = lib.recursiveUpdate base { storage.shares.smb.shares.media.gid = null; };
      imports = [ unixUsers ];
    }).warnings;
in
assert lib.assertMsg (media."valid users" == "ada machine-backup") "share should admit exactly its access list";
assert lib.assertMsg (media."read list" == "machine-backup") "ro principal should land in the read list";
assert lib.assertMsg (media."force group" == "storage-media") "share group default not applied";
assert lib.assertMsg (!(media ? "vfs objects")) "module must leave samba-native keys to the host";
assert lib.assertMsg (cfg.users.groups.storage-media.gid == 990) "share group not created with its gid";
assert lib.assertMsg (
  cfg.users.groups.storage-media.members == [
    "ada"
    "machine-backup"
  ]
) "share group members should be its access list";
assert lib.assertMsg (!cfg.services.samba.openFirewall) "samba's own openFirewall opens netbios ports";
assert lib.assertMsg (lib.elem 445 cfg.networking.firewall.allowedTCPPorts) "445 not opened";
assert lib.assertMsg (cfg.services.samba.settings.global."smb ports" == "445") "smbd should not listen on 139";
assert lib.assertMsg (lib.elem "ada:${password}" passwords.serviceConfig.LoadCredential)
  "principal password not loaded as a credential";
assert lib.assertMsg (lib.elem "machine-backup:${password}" passwords.serviceConfig.LoadCredential)
  "service-account password not loaded as a credential";
assert lib.assertMsg (lib.elem "/srv/storage/media/movies" permissions.unitConfig.RequiresMountsFor)
  "permissions unit must wait for every owned path";
assert lib.assertMsg (lib.elem "selfhost-smb-permissions.service" cfg.systemd.services.samba-smbd.requires)
  "smbd should require the permissions unit";
assert lib.assertMsg ungranted "grant to a principal with no SMB account did not fire";
assert lib.assertMsg noUnixUser "principal with no Unix user did not fire";
assert lib.assertMsg noPassword "principal with no passwordFile did not fire";
assert lib.assertMsg bothRegistries "name in both registries did not fire";
assert lib.assertMsg emptyAccess "share with no grants did not fire; an empty `valid users` admits everyone";
assert lib.assertMsg reservedName "share named `global` did not fire";
assert lib.assertMsg (lib.any (w: lib.hasInfix "no pinned gid" w) unpinned) "unpinned gid warning missing";
pkgs.runCommand "selfhost-shares-eval" { } "touch $out"
