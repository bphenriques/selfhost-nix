# Users

selfhost-nix models people and service identities as `selfhost.users.<name>`. Per-user attributes
**mirror the framework's top-level namespace 1:1**, so where an option lives tells you what it touches
and where to look for it:

- A bundled app's per-user options sit at `selfhost.users.<name>.apps.<app>` — mirroring `selfhost.apps.<app>`.
- A cross-cutting concern's per-user options sit at `selfhost.users.<name>.<concern>` — mirroring
  `selfhost.<concern>`, e.g. `auth.oidc.enable`, `vpn.wireguard.devices`.

```nix
selfhost.users.alice = {
  groups = [ "admin" ];
  apps.filebrowser = { enable = true; storage = { … }; };  # mirrors selfhost.apps.filebrowser
  auth.oidc.enable = true;                                  # mirrors selfhost.auth.oidc
  vpn.wireguard.devices = [ … ];                            # mirrors selfhost.vpn.wireguard
};
```

## Extending per-user as a consumer

selfhost-nix owns the `selfhost.users` schema and declares only what the framework itself needs. When
you want per-user knobs it doesn't provide — enriching a bundled app (per-user theming, say) or wiring
your **own** services — keep them in **your** namespace, not the framework's, so ownership stays obvious
from the path and the framework schema stays pristine:

- **Enriching a framework concern** → mirror its path under your root: `<root>.users.<name>.selfhost.<concern>`
  (the `selfhost.` segment signals "extends a selfhost-nix concern"; the rest is 1:1, e.g.
  `selfhost.apps.miniflux` for per-user Miniflux preferences).
- **A service not in selfhost-nix** → `<root>.users.<name>.services.<app>` (e.g. `services.jellyfin`); `services`
  marks it as yours, not the framework's.

Join your namespace with `selfhost.users` in your own modules. Because the framework lives at
`selfhost.users.<name>.<concern>` and your additions at `<root>.users.<name>.{selfhost,services}.<…>`,
`selfhost` never doubles up and every attribute's owner is readable at a glance.
