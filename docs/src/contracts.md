# Contracts & implementations

Every swappable concern is split in two: an **interface** — a provider-neutral contract that consuming
modules read — and an **implementation** that satisfies it. Consumers depend only on the interface, so
the bundled implementation can be replaced with your own without touching anything downstream.

## The standard

- The **interface** is `selfhost.<concern>` (e.g. `selfhost.notify`): the options other modules read,
  never knowing who fills them.
- An **implementation** is `selfhost.<concern>.<impl>` (e.g. `selfhost.notify.ntfy`), turned on with
  `.enable`, and it sets the interface's values when active.
- At most one implementation is active per interface. To swap, disable the bundled one and set the
  interface yourself.

## Interfaces and their implementations

| Interface          | Provides                                          | Bundled implementation                |
| ------------------ | ------------------------------------------------- | ------------------------------------- |
| `ingress`          | reverse-proxy routes + TLS for the registry       | Traefik — `ingress.traefik.enable`    |
| `auth.oidc`        | OIDC provider + user/group/client provisioning    | Pocket-ID — `auth.oidc.pocket-id.enable` |
| `auth.forwardAuth` | edge forward-auth gateway                         | tinyauth — `auth.forwardAuth.tinyauth.enable` |
| `notify`           | notification delivery (topics + `send-notification`) | ntfy — `notify.ntfy.enable`        |

One implementation each today — the split exists so a second can drop in cleanly, and so you can
replace any of them with your own reading the same interface.

## Subsystems are not swappable

`monitoring` (Prometheus/Alertmanager), `backup` (rustic), `vpn.wireguard`, and `storage.smb` have no
interface/implementation split: the tool *is* the contract. They're first-class subsystems, not
providers.
