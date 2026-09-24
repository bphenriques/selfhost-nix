# Concepts

One idea underpins everything: **declare a service once, and every cross-cutting concern reads from that
single definition.** This page is the model. The [options reference](options.md) is the per-option truth.

State the framework owns on disk â the secrets directory, backup trees, share mount points, the units it
generates â is prefixed `homelab-`. That is a naming convention, not a second namespace: every option
lives under `selfhost.`.

## The service registry

`selfhost.services.<name>` registers a service: the systemd units it owns, usually a backend
(`host`/`port`), and a derived public `url` (`https://<subdomain>.<domain>`). Registering isn't running.
You enable the upstream `services.<name>` and wire the values and secret files it derives (see
[Recipes](recipes.md)). That one entry is what capabilities attach to:

- `ingress.enable`: a reverse-proxy route at the public URL. On once the entry has a backend to route to
  and its `access.model` is satisfied (see below). Not the same as on by default.
- `access.model`: who authenticates this service's users (see below).
- `systemdServices`: the units concerns attach to, such as storage automount guards. Defaults to the
  service's own name, or its container's unit.
- `integrations.homepage` / `.monitoring` / `.notify`: a dashboard tile, health and metrics probes, and a
  publishing credential for notifications. These **default to their concern**. Enable monitoring or a
  notify provider globally and every service opts in (a tile follows having a route).
- `backup.package`: a pre-backup hook a target picks up.

That split holds for services you register. It does **not** hold for bundled apps (`selfhost.apps.<name>`)
or for the providers a concern brings with it: Traefik, Prometheus, Pocket ID, tinyauth, ntfy and the SMB
server each own their upstream `services.<name>` outright. You can still **add** keys alongside what they
set, but **replacing** one needs `lib.mkForce`, since both are definitions of the same option.

Not every entry owns a backend. Leave `port` unset for something that serves no HTTP at all â WireGuard
registers for its metadata and metrics, nothing more. Set `backend` to another entry's name to put a
second hostname onto one process, with its own access model and middlewares: that is how Radicale serves
`dav.<domain>` on htpasswd while its web UI sits behind the gateway. Only an entry that owns its socket
counts toward the port-collision check.

Data the framework doesn't model goes in `extraConfig`, a freeform slot on the entry that selfhost-nix
never reads. Attach your own per-service metadata there (a landing-page category, say) rather than a
separate tree keyed by service name, so it rides the same entry as the service. Read it back at
`config.selfhost.services.<name>.extraConfig`, and a consumer module can give it a type.

`selfhost.external.<name>` puts things this host doesn't run (a NAS) on the dashboard, without a route or
backend. Public hosts and listening ports are checked across the whole registry by one assertion, so two
services can't silently collide.

`selfhost.tasks.<name>` is the same shape for work that runs on a schedule rather than serving traffic â
backups, provisioning, DNS updates. It names the units it owns and requests the same storage and notify
integrations. Opting into notify gets it a failure alert, which fires once systemd has given up rather
than on an attempt it is about to retry.

Anything that renders your services — a landing page, a fleet view across hosts — reads the registry
directly. An entry already carries `displayName`, `meta.*`, `ingress.enable` and `publicUrl`, and
`extraConfig` is where your own presentation data rides along on the same entry.

## Concerns & contracts

A cross-cutting concern is a **provider-neutral interface** (`selfhost.<concern>`) that other modules read,
filled by at most one **implementation** (`selfhost.<concern>.<impl>.enable`). To swap it, disable the
bundled one and set the interface yourself. Defaults: Traefik (ingress + TLS), Pocket-ID (OIDC), tinyauth
(forward-auth), ntfy (notifications). Some concerns have no interface, because the tool *is* the contract
(Prometheus + Alertmanager, rustic backups, CIFS storage). Disable it and handle the concern yourself.

## Authentication

Every entry declares **who authenticates its users**, as `access.model`:

- `oidc` â the service is its own client of the provider, and users sign in there. Configure the client
  under `access.oidc`.
- `forwardAuth` â the edge authenticates first, for services with no SSO of their own.
- `native` â the service logs users in itself, by a mechanism the framework doesn't manage (Jellyfin).
- `open` â nobody authenticates.

One value, not a set of flags, because these are alternatives: a service is gated one way. Only the first
two put the framework in the request path, so only they enforce `access.allowedGroups` (empty = any
authenticated user). Under the other two the warning tells you the groups are decorative.

The model also decides whether a route appears at all. `forwardAuth` is the one model where the service
can authenticate *nobody* on its own, so it is routed only while a forward-auth provider is active â
without one it stays on localhost instead of going up unguarded. The rest carry their own login and route
regardless.

Clients, users, and groups are provisioned at boot, and credentials reach a service via `LoadCredential`
or a supplementary group, never the Nix store. Identities and their tiers are the [Users](users.md) model.

## First-party apps

A first-party app (`selfhost.apps.<name>.enable`, default-off) is a bundled application. Most register a
`selfhost.services.<name>` entry and inherit everything above from one toggle, framework-derived wiring
(users, storage, reconcilers) included. Most are HTTP behind ingress. A few aren't: WireGuard is an
ingress-less UDP server, and deSEC a headless DDNS timer. The catalog and each app's options are in the [reference](options.md).

## Secrets outside the store

`runtimeSecrets` generates values at boot into a persistent directory, never the Nix store or your secrets
backend. Each takes a missing-file policy: regenerate, leave absent, or generate-once for data-bound keys
(see the options). `runtimeTemplates` render config that must embed a secret into tmpfs, standing the value
in as a named placeholder so it never reaches the store. Rotation is deliberate: remove the value and restart
its generator (`oidc-rotate` wraps this for OIDC clients).

Which policy a secret wants follows from what it protects. A value the host can re-apply at will â an API
key a reconciler pushes back into its app â may regenerate whenever it goes missing. A value that encrypts
data at rest may not: a fresh key orphans the data it was meant to open. Those set `generateOnce` to the
path of the data they protect, and if the key is gone while that data is still there, the secret is left
**absent** with a log line saying why. Restore the key rather than letting a rebuild manufacture a new one.
A wiped host with no data to orphan generates cleanly on the next boot.

## Storage & dashboard tiles

`storage.mounts.smb.shares` are on-demand CIFS shares behind per-share access groups. Boot does not wait for the
SMB server. First access may wait up to 30 seconds. After a failed mount, a later access retries. A service
requests `storage.mounts = [ â¦ ]` to start its automount guards before the service can touch their paths. The
service still owns its failure and restart policy. Naming the users it runs as in `storage.users` also
grants them each share's access group, so a share is added in one place rather than two. A share with an
owner `uid` is skipped there, because its owner already reaches the files through the owner bits. That
means a *second* consumer of an owned share still needs the group granted by hand, and it fails loudly
when you forget. Converting a share that a previous generation
boot-mounted takes one reboot: systemd cannot install autofs over an already-mounted path. Dashboard tiles
come from services and externals that
opt into `integrations.homepage`, grouped by `group`. The bundled `apps.homepage` renders them, or read the
read-only `dashboards.generatedTiles` into your own. The framework supplies the data, you own the visuals.

## Exposure

Enabling an ingress implementation opens 80/443, since a proxy nobody can reach serves no purpose. Narrow
that to your LAN and VPN links with `ingress.allowedInterfaces`, or set `ingress.openFirewall = false` and
place the rules yourself. A single wildcard cert (`*.<domain>`) comes over ACME DNS-01, so issuance needs
no inbound port. Putting services on the **public internet is out of scope**. There is no bundled
hardening, and it is a security-sensitive decision you own.
