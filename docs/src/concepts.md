# Concepts

One idea underpins everything: **declare a service once, and every cross-cutting concern reads from that
single definition.** This page is the model. The [options reference](options.md) is the per-option truth.

## The service registry

`selfhost.services.<name>` registers a service: a backend (`host`/`port`) and a derived public `url`
(`https://<subdomain>.<domain>`). Registering isn't running. You enable the upstream `services.<name>` and
wire the values and secret files it derives (see [Recipes](recipes.md)). That one entry is what capabilities
attach to:

- `ingress.enable`: a reverse-proxy route at the public URL (on by default).
- `oidc.enable` / `forwardAuth.enable`: authentication, one or the other (see below).
- `integrations.homepage` / `.monitoring` / `.notify`: a dashboard tile, health and metrics probes, and
  failure alerts. These **default to their concern**. Enable monitoring or a notify provider globally and
  every service opts in (a tile follows having a route).
- `backup.package`: a pre-backup hook a target picks up.

Data the framework doesn't model goes in `extraConfig`, a freeform slot on the entry that selfhost-nix
never reads. Attach your own per-service metadata there (a landing-page category, say) rather than a
separate tree keyed by service name, so it rides the same entry as the service. Read it back at
`config.selfhost.services.<name>.extraConfig`, and a consumer module can give it a type.

`selfhost.external.<name>` puts things this host doesn't run (a NAS) on the dashboard, without a route or
backend. Public hosts and listening ports are checked across the whole registry by one assertion, so two
services can't silently collide.

## Concerns & contracts

A cross-cutting concern is a **provider-neutral interface** (`selfhost.<concern>`) that other modules read,
filled by at most one **implementation** (`selfhost.<concern>.<impl>.enable`). To swap it, disable the
bundled one and set the interface yourself. Defaults: Traefik (ingress + TLS), Pocket-ID (OIDC), tinyauth
(forward-auth), ntfy (notifications). Some concerns have no interface, because the tool *is* the contract
(Prometheus + Alertmanager, rustic backups, CIFS storage). Disable it and handle the concern yourself.

## Authentication

A service is gated one of two ways, never both. **OIDC** (`oidc.enable`) makes the app its own client, and
users sign in at the provider. **Forward-auth** (`forwardAuth.enable`) has the edge authenticate first, for
apps with no SSO. `access.allowedGroups` names who may enter (empty = any authenticated user). Clients,
users, and groups are provisioned at boot, and credentials reach a service via `LoadCredential` or a
supplementary group, never the Nix store. Identities and their tiers are the [Users](users.md) model.

## First-party apps

A first-party app (`selfhost.apps.<name>.enable`, default-off) is a bundled application. Most register a
`selfhost.services.<name>` entry and inherit everything above from one toggle. Apps that derive config from
the framework also expose `enableSelfhostIntegration` (default on) to opt out of *that* wiring while still
running. Most are HTTP behind ingress. A few aren't: WireGuard is an ingress-less UDP server, and deSEC a
headless DDNS timer. The catalog and each app's options are in the [reference](options.md).

## Secrets outside the store

`runtimeSecrets` generates values at boot into a persistent directory, never the Nix store or your secrets
backend. Each takes a missing-file policy: regenerate, leave absent, or generate-once for data-bound keys
(see the options). `runtimeTemplates` render config that must embed a secret into tmpfs via opaque
placeholders, so the value never reaches the store. Rotation is deliberate: remove the value and restart
its generator (`oidc-rotate` wraps this for OIDC clients).

## Storage & dashboard tiles

`storage.smb.mounts` are CIFS shares behind per-share access groups. A service requests `storage.smb =
[ … ]` and the mount dependency is wired onto its unit (boot-race-safe mode chosen per share). Dashboard
tiles come from services and externals that opt into `integrations.homepage`, grouped by `group`. The
bundled `apps.homepage` renders them, or read the read-only `dashboards.generatedTiles` into your own. The
framework supplies the data, you own the visuals.

## Exposure

HTTP is opened only on `ingress.allowedInterfaces` (LAN, VPN), keeping services off the public internet. A
single wildcard cert (`*.<domain>`) comes over ACME DNS-01, so issuance needs no inbound port. Putting
services on the **public internet is out of scope**. There is no bundled hardening, and it is a
security-sensitive decision you own.
