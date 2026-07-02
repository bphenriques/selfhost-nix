# Contracts & implementations

Every concern ships with one bundled implementation. Where it makes sense, that implementation sits
behind a **provider-neutral contract** you can disable and swap for your own; the rest are the contract
itself; exposing an interface there would cost more than it's worth, so you disable it and handle the
concern yourself.

| Concern               | Implementation            | Enable                             | Swappable |
| --------------------- | ------------------------- | ---------------------------------- | --------- |
| Ingress + TLS         | Traefik                   | `ingress.traefik.enable`           | yes       |
| OIDC / SSO            | Pocket-ID                 | `auth.oidc.pocket-id.enable`       | yes       |
| Forward-auth          | tinyauth                  | `auth.forwardAuth.tinyauth.enable` | yes       |
| Notifications         | ntfy                      | `notify.ntfy.enable`               | yes       |
| Dashboard             | Homepage                  | `apps.homepage.enable`             | yes       |
| Monitoring + alerting | Prometheus + Alertmanager | `monitoring.enable`                | no        |
| Backups               | rustic                    | `backup.targets`                   | no        |
| VPN                   | WireGuard                 | `vpn.wireguard.enable`             | no        |
| SMB storage           | CIFS                      | `storage.smb.enable`               | no        |

## How swapping works

- The **interface** is `selfhost.<concern>` (e.g. `selfhost.notify`): the options other modules read,
  never knowing who fills them.
- An **implementation** is `selfhost.<concern>.<impl>` (e.g. `selfhost.notify.ntfy`), turned on with
  `.enable`; it sets the interface when active. At most one is active per interface.
- A **swappable** concern: disable the bundled implementation and set the interface yourself. A
  non-swappable one has no interface: the tool *is* the contract; disable it and handle that concern
  however you like.

One implementation each today: the split exists so a second can drop in cleanly.
