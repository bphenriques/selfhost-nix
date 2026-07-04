# Users

selfhost-nix models people and service identities as `selfhost.users.<name>`, across three access tiers
via `groups` — `admin`, `users`, `guests`; at least one admin user is asserted (more is your call). Per-user attributes
**mirror the framework's top-level namespace 1:1**, so where an option lives tells you what it touches
and where to look for it:

- A bundled app's per-user options sit at `selfhost.users.<name>.apps.<app>` — mirroring `selfhost.apps.<app>`.
- A cross-cutting concern's per-user options sit at `selfhost.users.<name>.<concern>` — mirroring
  `selfhost.<concern>`, e.g. `auth.oidc.enable`.

```nix
selfhost.users.alice = {
  groups = [ "admin" ];
  apps.filebrowser = { enable = true; storage = { … }; };  # mirrors selfhost.apps.filebrowser
  apps.wireguard.devices = [ … ];                          # mirrors selfhost.apps.wireguard
  auth.oidc.enable = true;                                  # mirrors selfhost.auth.oidc
};
```

## Extending per-user as a consumer

For per-user knobs the framework doesn't provide — enriching a bundled app or wiring your **own** services
— use `selfhost.users.<name>.extraConfig`, a passthrough it never reads. Your data rides on the same user
object as its identity: no parallel user tree to join, and identity stays single-source.

Freeform by default, but a consumer module can declare typed options under it:

```nix
# your module — a typed per-user fragment under extraConfig
options.selfhost.users = lib.mkOption {
  type = lib.types.attrsOf (lib.types.submodule {
    options.extraConfig = lib.mkOption {
      type = lib.types.submodule {
        options.services.jellyfin.enable = lib.mkEnableOption "Jellyfin account for this user";
      };
    };
  });
};
```

Read it back off `config.selfhost.users.<name>`, which carries both the framework's `username`/`isAdmin`/…
and your `extraConfig.*`:

```nix
lib.filterAttrs (_: u: u.extraConfig.services.jellyfin.enable) config.selfhost.users
```
