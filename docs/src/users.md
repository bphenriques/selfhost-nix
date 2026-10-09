# Users

selfhost-nix models people and service identities as `selfhost.users.<name>`, across three access tiers
via `groups`: `admin`, `users`, `guests`. The same groups gate services
(`access.allowedGroups`) and SMB shares (`storage.shares.smb.shares.<name>.access.groups`). At least one admin user is asserted (more is your call). Per-user
attributes **mirror the framework's registry**, so where an option lives tells you what it touches:

- A user's per-service config sits at `selfhost.users.<name>.services.<service>` — for *any* service,
  bundled app or one you registered yourself — mirroring `selfhost.services.<service>`. (`selfhost.apps.<name>`
  is a deploy shortcut with no per-user surface, so per-user always belongs to the service.)
- A cross-cutting concern's per-user options sit at `selfhost.users.<name>.<concern>`, mirroring
  `selfhost.<concern>`, e.g. `auth.oidc.enable`.
- The same per-principal options are declared on `selfhost.serviceAccounts.<name>`, so a machine and a
  person are configured the same way. See [Shares](shares.md) for `storage.smb`.

```nix
selfhost.users.alice = {
  groups = [ "admin" ];
  services.filebrowser-quantum = { enable = true; storage = { … }; }; # per-user config for that service
  auth.oidc.enable = true;                                      # mirrors selfhost.auth.oidc
  storage.smb.enable = true;                                    # mirrors selfhost.storage.shares.smb
};
```

## Service accounts

`selfhost.serviceAccounts.<name>` is the same registry for non-human principals. They hold no groups, so
grants name them directly, and the framework provisions **identity and the credentials you declare, never
authorization inside the application**: whatever the account is then allowed to do is set where that
application keeps its permissions.

```nix
selfhost.serviceAccounts.personal-agent = {
  description = "An agent's forge principal, for git over SSH";
  services.gitea = {
    enable = true;
    sshKeys = [ { key = "ssh-ed25519 AAAA… agent@host"; } ];  # public half only; readOnly = true for a deploy key
  };
};
```

So a usable account is three steps: declare it with its public key, deploy, then grant it what it needs in
the application itself. See [Gitea](apps.md#gitea) for how that lands and how to read back what an account
holds.

## Extending per-user as a consumer

To give your **own** registered service a per-user surface, declare it at
`selfhost.users.<name>.services.<service>` — the same place a bundled app declares its own, mirroring the
top-level `selfhost.services.<service>`. Your data rides on the same user object as its identity, so there
is no parallel user tree to join and identity stays single-source.

```nix
# your module: a typed per-user fragment for your service
options.selfhost.users = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options.services.jellyfin.enable = lib.mkEnableOption "Jellyfin account for this user";
  });
};
```

Read it back off `config.selfhost.users.<name>`, which carries both the framework's `username`/`isAdmin`/…
and your per-service options:

```nix
lib.filterAttrs (_: u: u.services.jellyfin.enable) config.selfhost.users
```

For per-user data with **no** service to hang it on, use the never-read passthrough
`selfhost.users.<name>.extraConfig` instead.
