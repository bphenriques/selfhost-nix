# storage.shares.smb (eval-only): samba config, share groups and the guards are generated from the two
# principal registries. The VM test covers the running server; this covers what refuses to build.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  password = "/run/secrets/smb-password";

  person = groups: {
    email = "person@test.local";
    firstName = "Test";
    lastName = "Person";
    inherit groups;
    auth.oidc.enable = false;
    storage.smb = {
      enable = true;
      passwordFile = password;
    };
  };

  base = {
    users.ada = person [
      "family"
      "admin"
    ];
    users.bob = person [ "family" ];
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
      shares = {
        media = {
          path = "/srv/storage/media";
          owner = "ada";
          gid = 990;
          directories = [ "movies" ];
          access = {
            groups.family = "rw";
            users.machine-backup = "ro";
          };
        };
        # A user grant downgrades what the group gave.
        photos = {
          path = "/srv/storage/photos";
          gid = 991;
          access = {
            groups.family = "rw";
            users.bob = "ro";
          };
        };
        # ...and `none` revokes it outright.
        vault = {
          path = "/srv/storage/vault";
          gid = 992;
          access = {
            groups.family = "rw";
            users.bob = "none";
          };
        };
        # Several groups on one share: the most permissive wins.
        archive = {
          path = "/srv/storage/archive";
          gid = 993;
          access.groups = {
            family = "ro";
            admin = "rw";
          };
        };
        # A user grant upgrades as readily as it downgrades.
        boost = {
          path = "/srv/storage/boost";
          gid = 994;
          access = {
            groups.family = "ro";
            users.bob = "rw";
          };
        };
        # A personal share: nothing is implicit, not even for a holder of the admin group.
        home-bob = {
          path = "/srv/storage/home/bob";
          gid = 995;
          access.users.bob = "rw";
        };
      };
    };
  };

  # `common`'s admin is the only declared user, so give the people Unix identities the way a host would.
  unixUsers = {
    users.users.ada = {
      isNormalUser = true;
      uid = 4000;
    };
    users.users.bob = {
      isNormalUser = true;
      uid = 4001;
    };
  };

  cfg = evalConfig {
    selfhost = base;
    imports = [ unixUsers ];
  };

  share = name: cfg.services.samba.settings.${name};
  members = name: cfg.users.groups."storage-${name}".members;
  passwords = cfg.systemd.services.selfhost-smb-passwords;
  permissions = cfg.systemd.services.selfhost-smb-permissions;

  fires =
    module: infix:
    let
      c = evalConfig module;
    in
    lib.any (a: !a.assertion && lib.hasInfix infix a.message) c.assertions;

  warns = module: infix: lib.any (w: lib.hasInfix infix w) (evalConfig module).warnings;

  ungranted = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.media.access.users.stranger = "rw";
    };
    imports = [ unixUsers ];
  } "no SMB account";

  unknownGroup = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.media.access.groups.nosuch = "rw";
    };
    imports = [ unixUsers ];
  } "groups nobody is in";

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
  } "resolves to nobody";

  reservedName = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.global = {
        path = "/srv/g";
        access.users.ada = "rw";
      };
    };
    imports = [ unixUsers ];
  } "cannot be named";

  # `guests` is canonical, so it is a known group; nobody holding an SMB account is in it.
  unheldGroup = warns {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.media.access.groups.guests = "rw";
    };
    imports = [ unixUsers ];
  } "no SMB principal holds";

  unpinned = warns {
    selfhost = lib.recursiveUpdate base { storage.shares.smb.shares.media.gid = null; };
    imports = [ unixUsers ];
  } "no pinned gid";
in
assert lib.assertMsg (
  (share "media")."valid users" == "ada bob machine-backup"
) "a group grant should admit every principal holding it";
assert lib.assertMsg ((share "media")."read list" == "machine-backup") "ro principal should land in the read list";
assert lib.assertMsg ((share "photos")."valid users" == "ada bob") "user grant should not drop the principal";
assert lib.assertMsg ((share "photos")."read list" == "bob") "user grant should override the group level";
assert lib.assertMsg ((share "vault")."valid users" == "ada") "`none` should revoke what the group gave";
assert lib.assertMsg (!((share "vault") ? "read list")) "no ro principal should mean no read list";
assert lib.assertMsg ((share "archive")."valid users" == "ada bob") "both group members should be admitted";
assert lib.assertMsg ((share "archive")."read list" == "bob") "the most permissive of several groups should win";
assert lib.assertMsg ((share "media")."force group" == "storage-media") "share group default not applied";
assert lib.assertMsg (!((share "media") ? "vfs objects")) "module must leave samba-native keys to the host";
assert lib.assertMsg (cfg.users.groups.storage-media.gid == 990) "share group not created with its gid";
assert lib.assertMsg (
  members "media" == [
    "ada"
    "bob"
    "machine-backup"
  ]
) "share group members should be its resolved access list";
assert lib.assertMsg (members "vault" == [ "ada" ]) "a revoked principal must not stay in the share group";
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
assert lib.assertMsg unknownGroup "grant to an unknown group did not fire";
assert lib.assertMsg noUnixUser "principal with no Unix user did not fire";
assert lib.assertMsg noPassword "principal with no passwordFile did not fire";
assert lib.assertMsg bothRegistries "name in both registries did not fire";
assert lib.assertMsg emptyAccess "share with no grants did not fire; an empty `valid users` admits everyone";
assert lib.assertMsg reservedName "share named `global` did not fire";
assert lib.assertMsg unheldGroup "group grant that resolves to nobody did not warn";
assert lib.assertMsg unpinned "unpinned gid warning missing";
pkgs.runCommand "selfhost-shares-eval" { } "touch $out"
