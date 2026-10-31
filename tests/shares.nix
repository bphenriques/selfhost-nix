# storage.shares.smb (eval-only): samba config and the guards are generated from the two principal
# registries. The VM test covers the running server; this covers what refuses to build.
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
      unixAccount.enable = true;
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
          access = {
            groups.family = "rw";
            serviceAccounts.machine-backup = "ro";
          };
        };
        # A user grant downgrades what the group gave.
        photos = {
          path = "/srv/storage/photos";
          access = {
            groups.family = "rw";
            users.bob = "ro";
          };
        };
        # ...and `none` revokes it outright.
        vault = {
          path = "/srv/storage/vault";
          access = {
            groups.family = "rw";
            users.bob = "none";
          };
        };
        # Several groups on one share: the most permissive wins.
        archive = {
          path = "/srv/storage/archive";
          access.groups = {
            family = "ro";
            admin = "rw";
          };
        };
        # A user grant upgrades as readily as it downgrades.
        boost = {
          path = "/srv/storage/boost";
          access = {
            groups.family = "ro";
            users.bob = "rw";
          };
        };
        # A personal share: nothing is implicit, not even for a holder of the admin group.
        home-bob = {
          path = "/srv/storage/home/bob";
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

  # `bob` says nothing about a password, `ada` supplies one: only the first is minted a secret.
  # Replaced rather than merged, since `recursiveUpdate` would fold the fixture's `passwordFile` back in.
  generated = evalConfig {
    selfhost = base // {
      users = base.users // {
        bob = lib.removeAttrs (person [ "family" ]) [ "storage" ] // {
          storage.smb.enable = true;
        };
      };
    };
    imports = [ unixUsers ];
  };

  share = name: cfg.services.samba.settings.${name};
  passwords = cfg.systemd.services.selfhost-smb-passwords;

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
  } "not people with an SMB account";

  # Each grant names its own registry, so a machine under `users` is refused, and a person under
  # `serviceAccounts` too.
  machineAsUser = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.media.access.users.machine-backup = "rw";
    };
    imports = [ unixUsers ];
  } "not people with an SMB account";

  personAsServiceAccount = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.media.access.serviceAccounts.ada = "rw";
    };
    imports = [ unixUsers ];
  } "not service accounts with an SMB account";

  unknownGroup = fires {
    selfhost = lib.recursiveUpdate base {
      storage.shares.smb.shares.media.access.groups.nosuch = "rw";
    };
    imports = [ unixUsers ];
  } "groups nobody is in";

  noUnixUser = fires { selfhost = base; } "need a Unix user";

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
assert lib.assertMsg (
  cfg.selfhost.storage.shares.smb.shares.media.resolvedAccess == {
    ada = "rw";
    bob = "rw";
    machine-backup = "ro";
  }
) "resolvedAccess should be exactly what reaches samba";
assert lib.assertMsg (!((share "media") ? "vfs objects")) "module must leave samba-native keys to the host";
assert lib.assertMsg (!((share "media") ? "force group")) "ownership is the host's, not this module's";
assert lib.assertMsg (!(cfg.users.groups ? storage-media)) "the module must not create share groups";
assert lib.assertMsg (!cfg.services.samba.openFirewall) "samba's own openFirewall opens netbios ports";
assert lib.assertMsg (lib.elem 445 cfg.networking.firewall.allowedTCPPorts) "445 not opened";
assert lib.assertMsg (cfg.services.samba.settings.global."smb ports" == "445") "smbd should not listen on 139";
assert lib.assertMsg (lib.elem "ada:${password}" passwords.serviceConfig.LoadCredential)
  "principal password not loaded as a credential";
assert lib.assertMsg (lib.elem "machine-backup:${password}" passwords.serviceConfig.LoadCredential)
  "service-account password not loaded as a credential";
assert lib.assertMsg (lib.elem "/srv/storage/media" cfg.systemd.services.samba-smbd.unitConfig.RequiresMountsFor)
  "smbd must wait for every share path";
assert lib.assertMsg ungranted "grant to a person with no SMB account did not fire";
assert lib.assertMsg machineAsUser "service account granted under `users` did not fire";
assert lib.assertMsg personAsServiceAccount "person granted under `serviceAccounts` did not fire";
assert lib.assertMsg unknownGroup "grant to an unknown group did not fire";
assert lib.assertMsg noUnixUser "principal with no Unix user did not fire";
assert lib.assertMsg (
  generated.selfhost.users.bob.storage.smb.passwordFile == "/var/lib/homelab-secrets/smb-password-bob"
) "a principal that supplies no password should default to a generated one";
assert lib.assertMsg (
  generated.selfhost.runtimeSecrets ? smb-password-bob
) "the default password should actually be minted";
assert lib.assertMsg (
  !(generated.selfhost.runtimeSecrets ? smb-password-ada)
) "a principal supplying its own password should have nothing minted for it";
assert lib.assertMsg bothRegistries "name in both registries did not fire";
assert lib.assertMsg emptyAccess "share with no grants did not fire; an empty `valid users` admits everyone";
assert lib.assertMsg reservedName "share named `global` did not fire";
assert lib.assertMsg unheldGroup "group grant that resolves to nobody did not warn";
pkgs.runCommand "selfhost-shares-eval" { } "touch $out"
