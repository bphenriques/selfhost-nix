# Recipes

Best-effort examples focused on the *wiring* (how a service plugs into the framework), not on how you
configure the service itself. Contributions of new recipes are very welcome.

## Wiring a service (Miniflux + OIDC)

Declaring `selfhost.services.<name>` **registers** a service with the framework: its route, OIDC
client, dashboard tile, healthcheck, backup hook, and so on. It does **not** run the service: you still
enable the upstream NixOS service and connect it to the values the framework derives and the secret
files it generates.

A service module typically does three things:

```nix
{ config, lib, ... }:
let
  svc = config.selfhost.services.miniflux;
  oidc = config.selfhost.auth.oidc;
in
{
  # 1. Register it: route, OIDC client (admins only), dashboard tile, healthcheck.
  selfhost.services.miniflux = {
    port = 8081;
    healthcheck.path = "/healthcheck";
    access.allowedGroups = [ config.selfhost.groups.admin ];
    oidc = {
      enable = true;
      systemd.dependentServices = [ "miniflux" ]; # start miniflux after its client is provisioned
    };
    integrations.homepage.enable = true;
  };

  # 2. Run the upstream service, fed by the framework's derived values + generated secret files.
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

  # 3. Let miniflux read its generated OIDC credential files.
  systemd.services.miniflux.serviceConfig.SupplementaryGroups = svc.oidc.systemd.supplementaryGroups;
}
```

The framework owns the cross-cutting parts (route, client provisioning, tile, healthcheck, secrets)
and exposes everything you need as derived attributes (`svc.port`, `svc.publicUrl`, `svc.oidc.id.file`,
...), so nothing is hardcoded twice. You own the service itself and the handful of lines that connect
the two.

## More services

Most services need far less. Register them and enable the upstream module; your settings stay yours.

```nix
# Transmission: edge auth, since its RPC has no login of its own
{
  selfhost.services.transmission = {
    port = 9091;
    healthcheck.path = "/transmission/web/";
    forwardAuth.enable = true;
    integrations.homepage.enable = true;
  };

  services.transmission.enable = true; # download dirs, ratios, ... are yours
}
```

```nix
# Syncthing: its web GUI behind ingress; set a GUI password in Syncthing itself
{
  selfhost.services.syncthing = {
    port = 8384;
    healthcheck.path = "/rest/noauth/health";
    integrations.homepage.enable = true;
  };

  services.syncthing = {
    enable = true;
    guiAddress = "127.0.0.1:8384"; # your devices and folders go here
  };
}
```

```nix
# Jellyfin: native auth (users log in to Jellyfin), so no framework auth
{
  selfhost.services.jellyfin = {
    port = 8096;
    healthcheck.path = "/health";
    integrations.homepage.enable = true;
  };

  services.jellyfin.enable = true;
}
```

## Wiring a container (RomM)

Native NixOS services come first, but a container plugs into the registry the same way: bind it to
`127.0.0.1:<port>` and register that port. The framework proxies, monitors, and lists it like any other
service; it just doesn't manage the container's own requirements (database, volumes, env), which stay
yours.

```nix
{
  selfhost.services.romm = {
    port = 8095;
    healthcheck.path = "/api/heartbeat";
    forwardAuth.enable = true;
    integrations.homepage.enable = true;
  };

  virtualisation.oci-containers.containers.romm = {
    image = "rommapp/romm:<version>";
    ports = [ "127.0.0.1:8095:8080" ]; # bound to localhost; ingress reaches it
    # database, volumes, and env are the image's concern, not the framework's
  };
}
```
