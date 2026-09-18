# selfhost-nix

[![Nix Flakes](https://img.shields.io/badge/Nix-flakes-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)
[![Docs](https://img.shields.io/badge/docs-site-blue)](https://bphenriques.github.io/selfhost-nix)
[![Status](https://img.shields.io/badge/status-unstable-orange)](#out-of-scope)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

Self-hosting means wiring the same concerns into every service by hand: reverse proxy, auth, metrics, backups, notifications. This flake declares them once.

- **One declaration** sets reverse proxy, auth, monitoring, backups, and notifications.
- **SSO built in**: per-service OIDC with passwordless **passkeys** (Pocket-ID), or a forward-auth gateway for apps with no login of their own. Clients and secrets are provisioned and rotated for you.
- **Runtime secrets**: generated outside the Nix store, rotatable, declared like any other option.
- **Monitoring**: per-service metrics, healthchecks, and alerts, opt-in.
- **WireGuard access**: the default way in.
- **Opt-in throughout**: opinionated defaults, nothing on until you turn it on. Plenty is [out of scope](#out-of-scope).

This flake runs my own [homelab](https://github.com/bphenriques/dotfiles). Bundled services are nixpkgs services on nixpkgs' cadence, so releases are infrequent (spare-time work). Issues and PRs are welcome, though support is slow.

> [!WARNING]
> **Work in progress.** The framework grows as I hit the need. Docs are young, test coverage is partial, and options may change without migration notes until the next NixOS release.

## Getting Started

Check the [docs](https://bphenriques.github.io/selfhost-nix) on how to start, the [concepts](https://bphenriques.github.io/selfhost-nix/concepts.html), and [recipes](https://bphenriques.github.io/selfhost-nix/recipes.html).

For the curious, after most Flake ceremonies, it will resemble something like this:
```nix
{ config, ... }:
{
  selfhost = {
    ingress.domain                   = "home.example.com";
    ingress.traefik.enable           = true; # reverse proxy + TLS
    auth.oidc.pocket-id.enable       = true; # SSO (OIDC)
    auth.forwardAuth.tinyauth.enable = true; # forward-auth gateway
    notify.ntfy.enable               = true; # notifications
    monitoring.enable                = true; # metrics + alerting

    services.miniflux = {
      port = 8081;
      healthcheck.path = "/healthcheck";
      access.model = "oidc";
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

## Bundled apps

Each is `selfhost.apps.<name>.enable`, default-off. See [Bundled apps](https://bphenriques.github.io/selfhost-nix/apps.html).

| | |
|---|---|
| **Media** | `jellyfin` (media server), `immich` (photos), `romm` (ROM library) |
| **Media automation** | `radarr`, `sonarr`, `prowlarr`, `bazarr`, `transmission` — see [Media automation](https://bphenriques.github.io/selfhost-nix/media.html) |
| **Files & sync** | `filebrowser-quantum` (per-user file access), `radicale` (CalDAV/CardDAV), `couchdb` (document sync) |
| **Productivity** | `gitea` (git server), `miniflux` (RSS), `open-webui` (chat UI, unfree), `bentopdf` (PDF toolkit) |
| **Infrastructure** | `wireguard` (VPN), `desec` (dynamic DNS), `homepage` (dashboard) |

Concern providers come with their concern instead: Traefik, Pocket-ID, tinyauth, ntfy, Prometheus + Alertmanager, rustic, and the SMB server.

## What it wires vs what you set

This flake wires the cross-cutting concerns (ingress, auth, monitoring, backups, notifications) and each service's selfhost-specific glue. It does **not** wrap the `services.<name>` options nixpkgs already exposes for services you register: you still set paths, storage, and tuning on the upstream service yourself. Bundled apps and the providers a concern brings with it (Traefik, Prometheus, Pocket ID, ntfy, the SMB server) are the exception, and own their upstream module.

## Security

Secrets stay out of the Nix store. Each service gets OIDC or forward-auth and hardened units, and access is WireGuard-first. What stays yours: the keys behind secrets *you* supply (sops/age), **backups of generate-once keys** (lose one while its data survives and that data is gone), and host hardening. See the [Security chapter](https://bphenriques.github.io/selfhost-nix/security.html) for the full split and key-rotation guidance.

## Out of Scope

- **Public internet exposure**: the default way in is WireGuard. Exposing a service is a security decision this flake will not lighten for you.
- **Container networking**: bundled apps are native nixpkgs services. Your own containers register like anything else, as long as you publish to `127.0.0.1`. Published ports are DNAT'd ahead of the firewall's input rules, so `0.0.0.0` is exposure whatever `networking.firewall` says. Container networks, inter-container DNS, and volumes stay yours.
- **Multi-tenant**: one operator/household, no tenant isolation. More than one admin user is fine, but the framework does not partition data or access between tenants.
- **Non-NixOS**: no `nix-darwin` or other targets (for now).

## Development

```bash
nix fmt                                        # format + lint (treefmt)
nix flake check -L                             # run everything: formatting, package builds, and all VM tests
nix build -L .#checks.x86_64-linux.vm-ingress  # run a single VM test
nix build .#docs                               # docs site → result/index.html
```

VM tests ([`nixosTest`](https://nixos.org/manual/nixos/stable/#sec-nixos-tests), one concern per file under [`tests/`](tests/), Linux + KVM) are exposed as flake checks, so `nix flake check` runs them all in one go. Conventions and how to extend live in [`AGENTS.md`](AGENTS.md).

## Support

I don't expect anything back but if it saved you time and you feel like it, [buy me a coffee](https://buymeacoffee.com/bphenriques) ☕

## AI Disclaimer

AI was used to learn and iterate faster. I drive the architecture, review and own every line.

## License

MIT
