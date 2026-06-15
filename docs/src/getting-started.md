# Getting started

> ⚠️ **These services are meant for a private network — LAN or VPN, not the public internet.** The
> defaults harden nothing for internet exposure; doing it safely is entirely your responsibility and is
> [out of scope](ingress.md#exposure). Don't port-forward `80`/`443` to this host and assume it's safe.

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

That block **registers** miniflux with the framework — a Traefik route, a Pocket-ID client, a homepage
tile, and a Prometheus healthcheck — without repeating that wiring per service. It does not *run*
miniflux: you still enable the upstream `services.miniflux` and connect it to the generated files.
[Recipes](recipes.md) walks a service end to end; for a real host wiring a dozen, see
[bphenriques/dotfiles](https://github.com/bphenriques/dotfiles).

## Prerequisites

- A flake on **nixpkgs unstable**, with `selfhost-nix.inputs.nixpkgs.follows = "nixpkgs"`.
- A **secrets backend** ([sops-nix](https://github.com/Mic92/sops-nix), agenix, or plain files). The
  framework is path-based: every secret option takes a **file path**, never a value, and reads only that
  path — so nothing secret reaches the Nix store. You wire the paths; the backend is your choice.
