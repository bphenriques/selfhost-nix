# Getting started

> ⚠️ **These services are meant for a private network: LAN or VPN, not the public internet.** The
> defaults harden nothing for internet exposure. Doing it safely is entirely your responsibility and is
> [out of scope](concepts.md#exposure). Don't port-forward `80`/`443` to this host and assume it's safe.

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

Set `selfhost.enable` and `selfhost.domain`, then turn on the providers you want:
`ingress.traefik.enable`, `auth.oidc.pocket-id.enable`, `notify.ntfy.enable`, `monitoring.enable`. Now
register services with `selfhost.services.<name>`. Registering wires the cross-cutting parts (route,
auth, dashboard tile, healthcheck, secrets). It does **not** run the service. You enable the upstream
`services.<name>` and connect the values it derives. [Recipes](recipes.md) wires one end to end, and
[Concepts](concepts.md) explains the model.

## Prerequisites

- A flake on **nixpkgs unstable**, with `selfhost-nix.inputs.nixpkgs.follows = "nixpkgs"`.
- A **secrets backend** ([sops-nix](https://github.com/Mic92/sops-nix), agenix, or plain files). The
  framework is path-based: every secret option takes a **file path**, never a value, so nothing secret
  reaches the Nix store. You wire the paths, and the backend is yours.
