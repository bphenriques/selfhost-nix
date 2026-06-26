# First-party apps

A first-party app is a bundled application on top of the framework, enabled with
`selfhost.apps.<name>.enable` (default off). Enabling one brings up the implementation and registers a
[`selfhost.services.<name>`](services-registry.md) entry, so it gets ingress, a dashboard tile,
monitoring and the rest from that single toggle. They are curated, not exhaustive — anything else you
run yourself and register directly.

```nix
selfhost.apps.radicale.enable = true;            # run it + register the route
selfhost.services.radicale.port = 5300;          # tune anything on the registry entry (port has a default)
```

## Enable vs integration are orthogonal

`enable` runs the app. Apps that derive configuration from the framework also expose
`enableSelfhostIntegration` (default on) for *that* wiring — e.g. FileBrowser deriving users and storage
from `selfhost.users`, Radicale deriving its htpasswd from them. Turn it off to run the app but wire
those bits yourself.

Expose the flag only when the app has a meaningful *self-managed* user mode worth opting out of (an app
that owns its own accounts/htpasswd). OIDC-native apps — Gitea, Miniflux — provision through their auth
source unconditionally, so a `enableSelfhostIntegration` toggle there would gate nothing; omit it rather
than add it for symmetry.

## Defaults compose with the concerns you enabled

An app sets its registry entry with `mkDefault`, and the cross-cutting toggles **follow the matching
concern**: a service's `forwardAuth` defaults on only when a forward-auth gateway is active, monitoring
when monitoring is enabled, notifications when a notify provider is enabled. So enabling a concern
globally lights it up across your apps with no per-app wiring — and you override any of it on
`selfhost.services.<name>`.

## Catalog

| App | `selfhost.apps.<name>` | Notes |
|---|---|---|
| BentoPDF | `bentopdf` | Static PDF toolkit, served via darkhttpd. |
| FileBrowser | `filebrowser` | Per-user file sharing — see [FileBrowser](filebrowser.md). |
| Miniflux | `miniflux` | RSS reader with OIDC login (users auto-provision) + a bootstrap local admin. Reader preferences are UI-only; no per-user reconciler. |
| Radicale | `radicale` | CalDAV/CardDAV; htpasswd from `selfhost.users`. Warns if integration is on but no user opted in. With it off, you manage the htpasswd file yourself (the server won't start until it exists). |
| Transmission | `transmission` | Torrent client; download notifications when a notify provider is active. Download/incomplete dirs, seeding and the storage backing are yours to set on `services.transmission`. |
