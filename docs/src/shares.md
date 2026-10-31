# Shares

`selfhost.storage.shares.smb` serves shares over SMB, the counterpart to the
[`storage.mounts.smb`](concepts.md) client. A share is a door: a path, and who may come through it. The
backing store and the ownership of what is in it stay yours: a ZFS dataset, a BTRFS subvolume, a plain
directory, mounted and prepared before smbd starts.

Two things are separate on purpose. **Holding an account** is a property of a principal, so it lives on
`selfhost.users` or `selfhost.serviceAccounts`. **Being let into a share** is a property of the share, so
grants live next to the path, named after the registry they come from.

```nix
selfhost = {
  users.alice = {
    groups = [ "family" ];                    # the same group that gates services
    storage.smb = {
      enable = true;
      passwordFile = config.sops.secrets."samba/alice-password".path;
    };
  };

  serviceAccounts.machine-backup = {
    unixAccount.enable = true;                 # smbd drops to the connecting user, so it needs one
    storage.smb = {
      enable = true;
      passwordFile = config.sops.secrets."samba/machine-backup-password".path;
    };
  };

  storage.shares.smb = {
    enable = true;
    openFirewall = true;
    shares.media = {
      path = "/srv/storage/media";
      access = {
        groups.family = "rw";
        serviceAccounts.machine-backup = "ro";
      };
    };
  };
};
```

## Who gets in

| Grant | Names | Levels |
|---|---|---|
| `access.groups` | groups from `selfhost.users.<name>.groups` | `rw`, `ro` |
| `access.users` | people in `selfhost.users` | `rw`, `ro`, `none` |
| `access.serviceAccounts` | machines in `selfhost.serviceAccounts` | `rw`, `ro` |

`access.groups` uses the same groups as `access.allowedGroups` on services, so one group name drives both.
It is additive: a person holding several groups gets the most permissive grant among them.

`access.users` **takes precedence** over whatever the groups produced for that person, in either
direction. `"ro"` downgrades a group's `"rw"`, and `"none"` revokes the grant outright:

```nix
access = {
  groups.family = "rw";
  users.teenager = "none";                    # in `family`, but not on this share
};
```

Service accounts hold no groups, so `access.serviceAccounts` is their only way in and has no `"none"`.
There is no `"none"` under `groups` either: a group grant is taken away per person, not by a second group.

`resolvedAccess` reads back the outcome per share, which is also what reaches samba, so `testparm` shows
the expanded names rather than a group reference you would have to resolve by hand.

## Ownership is yours

smbd drops to the connecting principal, so the files need a group every principal of a tree belongs to.
This module does not pick one: whether that is a group per dataset, ACLs or something else depends on your
storage. The common shape is a setgid group per tree, with any number of doors into it:

```nix
let
  shares = config.selfhost.storage.shares.smb.shares;
  doors = [ "media" "movies" ];               # movies.path is /srv/storage/media/movies
in
{
  users.groups.storage-media = {
    gid = 990;                                # pin it: the data outlives the root that recorded it
    members = lib.unique (lib.concatMap (d: lib.attrNames shares.${d}.resolvedAccess) doors);
  };

  systemd.tmpfiles.rules = [
    "d /srv/storage 0755 root root -"          # smbd must traverse the parent as the connecting user
    "z /srv/storage/media 2770 alice storage-media -"
  ];

  services.samba.settings = lib.genAttrs doors (_: {
    "force group" = "storage-media";
    "create mask" = "0660";
    "directory mask" = "2770";
    "force create mode" = "0660";
    "force directory mode" = "2770";
  });
}
```

A door into a subdirectory confines its principal there: samba does not follow a link out of a share
unless `wide links` is set, even though the principal's group reaches the whole tree.

## What it asserts

Samba fails open in two ways this module refuses to let you reach. A share whose `access` resolves to
nobody emits an empty `valid users`, which samba reads as *no restriction*, admitting every principal that
can authenticate. And a share named `global` would replace the global section, dropping every hardening
line with it. Both are assertions, as are: a grant naming someone not in that grant's registry or without an
SMB account (samba silently never matches such a name), a grant to a group nobody is in, and a principal
with no Unix user.

A group that *is* known but that no SMB principal holds warns instead of failing, since it names the one
way this indirection disappoints quietly: the members need `storage.smb.enable` before a group grant
reaches them.

The passdb is reconciled, not just appended: an account that is no longer a declared principal is deleted,
so revoking access is a config change rather than a config change plus `pdbedit -x`.

smbd waits for every share path to be mounted, so an unmounted dataset is never served as whatever sits on
the root filesystem beneath it.

## Filesystem-specific bits

One: `path`. Everything else samba already exposes stays samba's. Windows "Previous Versions" is the
example: this module sets no `shadow:*` keys, so a host adds them for its own snapshot layout:

```nix
services.samba.settings = lib.mapAttrs (_: _: {
  "vfs objects" = "shadow_copy2";
  "shadow:snapdir" = ".zfs/snapshot";          # BTRFS would name its own
  "shadow:snapdirseverywhere" = "yes";
  "shadow:format" = "autosnap_%Y-%m-%d_%H:%M:%S_hourly";
}) cfg.shares;
```

`shadow:format` must match a *whole* snapshot name; a pattern matching part of one surfaces nothing at all.

## Overriding generated samba settings

`browseable`, `read only`, `valid users`, `read list` and the hardened global section are not options. You
can **add** keys to a generated section through `services.samba.settings.<share>`, but **replacing** a key
this module sets needs `lib.mkForce`, since both are definitions of the same option.

Clients must speak SMB 3.1.1: `server min protocol = SMB3` is a samba alias for `SMB3_11`, not `SMB3_00`.
