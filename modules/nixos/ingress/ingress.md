# Ingress & TLS

Every service with `ingress.enable` (the default) is routed from `https://<subdomain>.<domain>` to its
local backend. Routing is provider-neutral: the registry holds the routes and the active implementation
(Traefik by default, `ingress.traefik.enable`) reads them — disable it and supply your own reading the
same registry.

## TLS

A single wildcard certificate (`*.<domain>`) is obtained over ACME DNS-01, so issuance never needs an
inbound port and one cert covers every subdomain. Point `ingress.acme` at your DNS provider and an env
file holding its API token, wired from your secrets backend.

## Exposure

HTTP is opened only on `allowedInterfaces` (e.g. LAN and VPN), keeping services off the public internet.
Per-service authentication at the edge is opt-in through `forwardAuth.enable`.
