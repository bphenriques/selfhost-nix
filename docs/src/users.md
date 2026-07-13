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

## WireGuard devices

Each entry in `apps.wireguard.devices` is a **declarative peer** — the server routes its `ip` to its
`publicKey`. Keys are provisioned in two phases: the private key is minted on the server and never leaves it;
the public key (not secret) is declared in config, so peers apply declaratively — no runtime `wg set`.

1. **Mint on the server** (the WireGuard host). The client name is `<username>-<device>`; pass the short
   `--device` so the generated interface name stays within 15 chars:
   ```console
   $ sudo wg-manage add alice-phone --device phone
   Client 'alice-phone' provisioned (10.100.0.42)
     publicKey = "kQ…="
   # also prints the config QR
   ```
   The private key lands in `/var/lib/wireguard/clients/` (0600, root); the public key and IP are printed.

2. **Declare it** with the printed IP + public key, then rebuild:
   ```nix
   selfhost.users.alice.apps.wireguard.devices = [
     { name = "phone"; ip = "10.100.0.42"; fullAccess = true; publicKey = "kQ…="; }
   ];
   ```
   `fullAccess = true` reaches the whole LAN; `false` reaches only the server.

Re-show a QR with `sudo wg-manage show alice-phone`; `wg-manage status` lists handshakes. To remove a device,
delete it from the registry and rebuild, then `sudo wg-manage remove alice-phone` to wipe its key.

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
