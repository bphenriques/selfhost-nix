# Recipes

[First-party apps](concepts.md#first-party-apps) pre-wire a curated few. This is the other side: how you
**register a service the framework doesn't bundle** — the wiring an app does for you, by hand. For real,
always-current examples see [Examples in the wild](#examples-in-the-wild).

`selfhost.services.<name>` **registers** a service — route, OIDC client, dashboard tile, healthcheck,
backup hook. It does **not** run it: you enable the upstream service and feed it the values the framework
derives and the secret files it generates.

## Wiring a service (Miniflux + OIDC)

```nix
{ config, lib, ... }:
let
  svc = config.selfhost.services.miniflux;
  oidc = config.selfhost.auth.oidc;
in
{
  # 1. Register: route, OIDC client (admins only), tile, healthcheck.
  selfhost.services.miniflux = {
    port = 8081;
    healthcheck.path = "/healthcheck";
    access.allowedGroups = [ config.selfhost.groups.admin ];
    oidc = {
      enable = true;
      systemd.dependentServices = [ "miniflux" ]; # start after its client is provisioned
    };
    integrations.homepage.enable = true;
  };

  # 2. Run it, fed by the derived values + generated secret files.
  services.miniflux = {
    enable = true;
    createDatabaseLocally = true;
    config = {
      LISTEN_ADDR = "127.0.0.1:${toString svc.port}";
      BASE_URL = svc.publicUrl;
      OAUTH2_PROVIDER = "oidc";
      OAUTH2_USER_CREATION = 1;
      OAUTH2_OIDC_DISCOVERY_ENDPOINT = oidc.provider.issuerUrl;
      OAUTH2_OIDC_PROVIDER_NAME = oidc.provider.displayName;
      OAUTH2_REDIRECT_URL = builtins.head svc.oidc.callbackURLs;
      OAUTH2_CLIENT_ID_FILE = svc.oidc.id.file; # provisioned at boot
      OAUTH2_CLIENT_SECRET_FILE = svc.oidc.secret.file; # never in the Nix store
    };
  };

  # 3. Let miniflux read those files (it takes them as *_FILE env vars).
  systemd.services.miniflux.serviceConfig.SupplementaryGroups = svc.oidc.systemd.supplementaryGroups;
}
```

The framework owns the route, client provisioning, tile, healthcheck, and secrets, and exposes them as
derived attributes (`svc.publicUrl`, `svc.oidc.id.file`, …). You own the service and the few lines that
connect the two.

## Variations

Same shape — register, run, wire — with small deltas:

- **Secrets in-settings** (e.g. Immich): a service that takes a file *path* in its own config skips the env
  vars — `settings.oauth = { inherit (oidc.provider) issuerUrl; clientId._secret = svc.oidc.id.file;
  clientSecret._secret = svc.oidc.secret.file; }` — but still needs the supplementary group, since it reads
  those files as its own user (`SupplementaryGroups = svc.oidc.systemd.supplementaryGroups`).
- **Forward-auth instead of OIDC** (no SSO of its own): drop the `oidc` block, set `forwardAuth.enable =
  true`; the edge authenticates.
- **Native auth** (the app logs users in itself, e.g. Jellyfin): register for the route and tile, enable no
  framework auth.
- **A container**: bind it to `127.0.0.1:<port>` and register that port — proxied and monitored like any
  native service; its database, volumes, and env stay yours.

## Resource limits

Throttling or prioritising a service is host-specific tuning — plain systemd, no framework option. Target the
unit by name; use a per-service cap or a shared slice. (Some upstream modules pin their own slice, e.g. Immich
— override with `lib.mkForce`.)

```nix
systemd.services.jellyfin.serviceConfig.CPUQuota = "150%"; # per-service cap

# or a shared budget across services
systemd.slices.media.sliceConfig = {
  CPUQuota = "300%";
  MemoryHigh = "8G";
};
systemd.services.jellyfin.serviceConfig.Slice = "media.slice";
systemd.services.immich-server.serviceConfig.Slice = lib.mkForce "media.slice";
```

## Examples in the wild

[bphenriques/dotfiles](https://github.com/bphenriques/dotfiles) is the reference deployment: a real host
wiring a couple dozen services — \*arr stack, Jellyfin, Immich, containers, tasks, backups — always in sync
with this flake. The exhaustive catalogue this page deliberately isn't.
