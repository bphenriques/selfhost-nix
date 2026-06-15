# selfhost-nix

[![Nix Flakes](https://img.shields.io/badge/Nix-flakes-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)
[![Docs](https://img.shields.io/badge/docs-site-blue)](https://bphenriques.github.io/selfhost-nix)
[![Status](https://img.shields.io/badge/status-unstable-orange)](#out-of-scope)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

The major hindrance when self-hosting is keeping a clean(er) design across reverse proxy, OIDC, metrics, backups, and notifications without repeating the same wiring for every service. My goal is to help those who pursue self-hosting as a hobby and face similar issues:

- **Single declaration**: one definition sets reverse proxy, authentication, monitoring, backups and notifications.
- **Open for extension**: interface-first design with at least one implementation provided for those who want to start with _something_.
- **Automated OIDC clients**: automatically provision OIDC clients per service (scoped to specific groups).
- **Automated runtime secrets**: following a familiar interface, each service may declare runtime secrets safely stored outside the Nix store.
- **WireGuard Access**: provides a simple WireGuard (VPN) implementation for (safer) access to the local network.
- **Opinionated**: on purpose. There are many options out there and plenty is out of scope to keep this project simple(r). Read below ([what is out of scope](#out-of-scope)).

This flake is the foundation of my own [self-hosting environment](https://github.com/bphenriques/dotfiles). I hope it is useful for you. I work on it in spare time, so support is slow, but issues and PRs are welcome.

> [!WARNING]
> **Work in progress** — expect some rough edges:
>
> 1. You might not find what you need. The framework grows as I hit the need, though it is open to simple, idiomatic extensions.
> 2. Docs are young and still filling in.
> 3. Partial automated test coverage.
> 4. Options may change without migration notes until at least the next NixOS release.

## Getting Started

Check the [docs](https://bphenriques.github.io/selfhost-nix) on how to start, the [providers](https://bphenriques.github.io/selfhost-nix/contracts.html), and [recipes](https://bphenriques.github.io/selfhost-nix/recipes.html). 

For the curious, after most Flake ceremonies, it will resemble something like this:
```nix
{ config, ... }:
{
  selfhost = {
    enable = true;
    domain = "home.example.com";

    ingress.traefik.enable           = true; # reverse proxy + TLS
    auth.oidc.pocket-id.enable       = true; # SSO (OIDC)
    auth.forwardAuth.tinyauth.enable = true; # forward-auth gateway
    notify.ntfy.enable               = true; # notifications
    monitoring.enable                = true; # metrics + alerting

    services.miniflux = {
      port = 8081;
      healthcheck.path = "/healthcheck";
      oidc.enable = true;
      integrations.homepage.enable = true;
      integrations.monitoring.enable = true;
    };
  };

  services.miniflux = {
    enable = true;
    # wire the selfhost-generated files (OIDC client/secret, derived URL/port) into miniflux
  };
}
```

The `selfhost.services.miniflux` block **registers** a Traefik route at `miniflux.home.example.com`, a dedicated Pocket-ID client, a homepage tile, and a healthcheck. You still enable the upstream `services.miniflux` and wire in the generated files.

## Out of Scope

- **Public internet exposure**: default setup promotes WireGuard. Putting services on the public internet is a security decision that needs careful consideration and this flake will not lighten that decision for you.
- **Containers**: bundled services are native NixOS/nixpkgs services to keep maintenance burden low. You can run containers yourself and wire through `selfhost.services`.
- **All combinations**: only what NixOS/nixpkgs supports natively _might_ get bundled. I do not want to carry the maintenance.
- **Multi-admin / multi-tenant**: Single admin by design. Keeps things simple and matches the nature of the hobby.
- **Non-NixOS**: no `nix-darwin` or other targets (for now).

## Development

```bash
nix fmt                                        # format + lint (treefmt)
nix flake check -L                             # run everything: formatting, package builds, and all VM tests
nix build -L .#checks.x86_64-linux.vm-ingress  # run a single VM test
nix build .#docs                               # docs site → result/index.html
```

VM tests ([`nixosTest`](https://nixos.org/manual/nixos/stable/#sec-nixos-tests), one concern per file under [`tests/`](tests/); Linux + KVM) are exposed as flake checks, so `nix flake check` runs them all in one go. Conventions and how to extend live in [`AGENTS.md`](AGENTS.md).

## Support

I don't expect anything back but if it saved you time and you feel like it, [buy me a coffee](https://buymeacoffee.com/bphenriques) ☕

## AI Disclaimer

AI was used to learn and iterate faster. I drive the architecture, review and own every line.

## License

MIT
