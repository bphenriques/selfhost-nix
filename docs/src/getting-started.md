# Getting started

## Add the flake input

```nix
# flake.nix
inputs.selfhost-nix.url = "github:bphenriques/selfhost-nix";
inputs.selfhost-nix.inputs.nixpkgs.follows = "nixpkgs";
```

Import the module into a host:

```nix
imports = [ inputs.selfhost-nix.nixosModules.default ];
```

## Enable it

Turn on the providers you want, set the base domain, then declare services:

```nix
selfhost = {
  enable = true;
  domain = "home.example.com";

  ingress.traefik.enable     = true;
  auth.oidc.pocket-id.enable = true;
  notify.ntfy.enable         = true;
  monitoring.enable          = true;

  services.miniflux = {
    port = 8081;
    healthcheck.path = "/healthcheck";
    oidc.enable = true;
    integrations.homepage.enable = true;
    integrations.monitoring.enable = true;
  };
};
```

That one `services.miniflux` block yields a Traefik route at `miniflux.home.example.com`, a Pocket-ID
OIDC client, a homepage tile, and a Prometheus healthcheck. Each concern is off until enabled, so start
with what you need and grow into the rest — the [Service registry](services-registry.md) chapter explains
what a declaration wires up.

## Prerequisites

- A flake on **nixpkgs unstable**, with `selfhost-nix.inputs.nixpkgs.follows = "nixpkgs"`.
- A **secrets backend** ([sops-nix](https://github.com/Mic92/sops-nix), agenix, or plain files). The
  framework is path-based: every secret option takes a **file path**, never a value, and reads only that
  path — so nothing secret reaches the Nix store. You wire the paths; the backend is your choice.
