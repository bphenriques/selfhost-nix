# Users

selfhost-nix models people and service identities as `selfhost.users.<name>`, across three access tiers
via `groups`: `admin`, `users`, `guests`. The same groups gate services
(`access.allowedGroups`) and SMB shares (`storage.shares.smb.shares.<name>.access.groups`). At least one admin user is asserted (more is your call). Per-user
attributes **mirror the framework's registry**, so where an option lives tells you what it touches:

- A user's per-service config sits at `selfhost.users.<name>.services.<service>` — for *any* service,
  bundled app or one you registered yourself — mirroring `selfhost.services.<service>`. (`selfhost.apps.<name>`
  is a deploy shortcut with no per-user surface; per-user always belongs to the service.)
- A cross-cutting concern's per-user options sit at `selfhost.users.<name>.<concern>`, mirroring
  `selfhost.<concern>`, e.g. `auth.oidc.enable`.
- The same per-principal options are declared on `selfhost.serviceAccounts.<name>`, so a machine and a
  person are configured the same way. See [Shares](shares.md) for `storage.smb`.

```nix
selfhost.users.alice = {
  groups = [ "admin" ];
  services.filebrowser-quantum = { enable = true; storage = { … }; }; # per-user config for that service
  services.wireguard.devices = [ … ];                          # per-user config for the wireguard service
  auth.oidc.enable = true;                                      # mirrors selfhost.auth.oidc
  storage.smb.enable = true;                                    # mirrors selfhost.storage.shares.smb
};
```

## WireGuard devices

Each entry in `services.wireguard.devices` is a **declarative peer**: the server routes its `ip` to its
`publicKey`. The registry is the only inventory. `wg-manage` stores nothing, so there is no local state
to drift from it, and allocation, access policy and status all read the same list.

Only the private key is out of band, and there are two ways to get one.

**Either the device generates it**, so no private key for that person exists anywhere but their phone:

```console
$ sudo wg-manage invite --device phone > alice-phone.conf
Send the config below. In the WireGuard app: import it, Edit, regenerate the Private Key,
then send back the Public Key.
Declare it and rebuild before telling them to connect:
  { name = "phone"; ip = "10.100.0.2"; fullAccess = false; publicKey = "<theirs>"; }
```

The key inside that file is a throwaway that is never declared, so the tunnel stays dead until they
regenerate it: a skipped step fails closed rather than leaving a server-minted key in use.

**Or `issue` mints one** and renders its QR once, for someone who cannot manage that. Nothing is stored,
so losing the output means issuing again, which is the same answer as a lost phone.

Both take `--ip`, otherwise picking the next free address in `clientSubnet`, and both print the registry
line matching the config they rendered. Pass `--full-access` for a device that should reach the LAN: a
not-yet-declared device has no registry entry to resolve from, so without it the config would route only
the server while the line you paste says otherwise.

**Then declare it** and rebuild:

```nix
selfhost.users.alice.services.wireguard.devices = [
  { name = "phone"; ip = "10.100.0.2"; fullAccess = true; publicKey = "kQ…="; }
];
```

`fullAccess = true` reaches the whole LAN. `false` reaches the server only, on
`apps.wireguard.restrictedPeerPorts` (80 and 443 by default) and nothing else, and its config routes just
`lanAccess.serverAddress` instead of the whole subnet, so a client whose home network overlaps yours keeps
its own devices reachable.

`wg-manage status` lists declared peers and their last handshake. **To revoke, delete the device from the
registry and rebuild.** systemd-networkd never removes a peer it no longer declares, so
`wireguard-reconcile-peers` does it on deploy.

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
