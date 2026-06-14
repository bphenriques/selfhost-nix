# Service registry

The registry is the heart of the framework: `selfhost.services.<name>` declares a service once, and
every concern reads from that single definition. From a port and a few flags you get a routed,
monitored, backed-up, discoverable service — no per-service wiring.

## What a declaration gives you

An entry carries its own routing identity — `host`/`port` for the backend and a derived public `url`
(`https://<subdomain>.<domain>`). From there, opt-in integrations attach to it:

- `ingress.enable` (default) — a reverse-proxy route at the public URL.
- `oidc.enable` / `forwardAuth.enable` — authentication.
- `integrations.homepage` / `integrations.monitoring` / `integrations.notify` — a dashboard tile,
  health/metrics, failure alerts.
- `backup.package` — a pre-backup hook a backup target can pick up.

Each subsystem filters the registry for the services that opted into it, so adding a capability is one
flag, not a new wiring block.

## External entries

`selfhost.external.<name>` registers things this host doesn't run (a NAS, another box) so they show up
on the dashboard alongside real services, without a route or backend.

## Safety

Public hostnames and local listening ports are gathered across the whole registry and checked by a
single assertion, so two services can't silently claim the same host or port.
