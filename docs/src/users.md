# Users

selfhost-nix models people and service identities as `selfhost.users.<name>`, across three access tiers
via `groups`: `admin`, `users`, `guests`. At least one admin user is asserted (more is your call). Per-user
attributes **mirror the framework's registry**, so where an option lives tells you what it touches:

- A user's per-service config sits at `selfhost.users.<name>.services.<service>` — for *any* service,
  bundled app or one you registered yourself — mirroring `selfhost.services.<service>`. (`selfhost.apps.<name>`
  is a deploy shortcut with no per-user surface; per-user always belongs to the service.)
- A cross-cutting concern's per-user options sit at `selfhost.users.<name>.<concern>`, mirroring
  `selfhost.<concern>`, e.g. `auth.oidc.enable`.

```nix
selfhost.users.alice = {
  groups = [ "admin" ];
  services.filebrowser = { enable = true; storage = { … }; };  # per-user config for the filebrowser service
  services.wireguard.devices = [ … ];                          # per-user config for the wireguard service
  auth.oidc.enable = true;                                      # mirrors selfhost.auth.oidc
};
```

## WireGuard devices

Each entry in `services.wireguard.devices` is a **declarative peer**. The server routes its `ip` to its
`publicKey`. Keys are provisioned in two phases. The private key is minted on the server and never leaves
it. The public key (not secret) is declared in config, so peers apply declaratively with no runtime
`wg set`.

1. **Mint on the server** (the WireGuard host). The client name is `<username>-<device>`. Pass the short
   `--device` so the generated interface name stays within 15 chars:
   ```console
   $ sudo wg-manage add alice-phone --device phone
   Client 'alice-phone' provisioned (10.100.0.42)
     publicKey = "kQ…="
   # also prints the config QR
   ```
   The private key lands in `/var/lib/wireguard/clients/` (0600, root). The public key and IP are printed.

2. **Declare it** with the printed IP + public key, then rebuild:
   ```nix
   selfhost.users.alice.services.wireguard.devices = [
     { name = "phone"; ip = "10.100.0.42"; fullAccess = true; publicKey = "kQ…="; }
   ];
   ```
   `fullAccess = true` reaches the whole LAN. `false` reaches only the server.

Re-show a QR with `sudo wg-manage show alice-phone`. `wg-manage status` lists handshakes. To remove a
device, delete it from the registry and rebuild, then `sudo wg-manage remove alice-phone` to wipe its key.

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
