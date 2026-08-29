# Shares

`selfhost.storage.shares.smb` serves shares over SMB, the counterpart to the
[`storage.mounts.smb`](concepts.md) client. It exports and guards paths; it never creates them. The
backing store stays yours: a ZFS dataset, a BTRFS subvolume, a plain directory, mounted before the units
below run.

Two things are separate on purpose. **Holding an account** is a property of a principal, so it lives on
`selfhost.users` or `selfhost.serviceAccounts`. **Being let into a share** is a property of the share, so
grants live next to the path. Neither implies the other: a share may be owned by a principal holding no
grant on it, which is what you want when its data is reached through an application rather than over SMB.

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
    systemUser.enable = true;                 # smbd drops to the connecting user, so it needs one
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
      owner = "alice";
      gid = 990;
      directories = [ "movies" ];             # created, or ownership-fixed if the host mounted them
      access = {
        groups.family = "rw";
        users.machine-backup = "ro";
      };
    };
  };
};
```

## Who gets in

`access.groups` names groups from `selfhost.users.<name>.groups`, the same ones `access.allowedGroups`
uses to gate services, so one group name drives both. It is additive: a principal holding several groups
gets the most permissive grant among them.

`access.users` names principals directly and **takes precedence** over whatever the groups produced for
them, in either direction. `"ro"` downgrades a group's `"rw"`, and `"none"` revokes the grant outright:

```nix
access = {
  groups.family = "rw";
  users = {
    machine-backup = "ro";                    # service accounts hold no groups, so they go here
    teenager = "none";                        # in `family`, but not on this share
  };
};
```

There is deliberately no `"none"` under `groups`: a group grant is taken away per principal, not by a
second group. The resolved list is what reaches samba, so `testparm` shows the expanded names rather than
a group reference you would have to resolve by hand.

## What it asserts

Samba fails open in two ways this module refuses to let you reach. A share whose `access` resolves to
nobody emits an empty `valid users`, which samba reads as *no restriction*, admitting every principal that
can authenticate. And a share named `global` would replace the global section, dropping every hardening
line with it. Both are assertions, as are: a grant to a principal with no SMB account (samba silently
never matches such a name), a grant to a group nobody is in, a principal or `owner` with no Unix user,
and an enabled principal with no `passwordFile`.

A group that *is* known but that no SMB principal holds warns instead of failing, since it names the one
way this indirection disappoints quietly: the members need `storage.smb.enable` before a group grant
reaches them.

The passdb is reconciled, not just appended: an account that is no longer a declared principal is deleted,
so revoking access is a config change rather than a config change plus `pdbedit -x`.

`gid` is optional and warns while unset. Pin it once the share holds data: the group allocation is
recorded only on the root filesystem, and the data outlives it.

## Filesystem-specific bits

One: `path`. Everything else samba already exposes stays samba's. Windows "Previous Versions" is the
example — this module sets no `shadow:*` keys, so a host adds them for its own snapshot layout:

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

The per-share masks (`0660`/`2770`), `browseable` and the hardened global section are not options. You
can **add** keys to a generated section through `services.samba.settings.<share>`, but **replacing** a
key this module sets needs `lib.mkForce`, since both are definitions of the same option.

Clients must speak SMB 3.1.1: `server min protocol = SMB3` is a samba alias for `SMB3_11`, not `SMB3_00`.
