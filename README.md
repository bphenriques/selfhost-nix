# selfhost-nix

[![Nix Flakes](https://img.shields.io/badge/Nix-flakes-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)
[![Docs](https://img.shields.io/badge/docs-site-blue)](https://bphenriques.github.io/selfhost-nix)
[![Status](https://img.shields.io/badge/status-unstable-orange)](#status--scope)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

The major hindrance when self-hosting is keeping a clean(er) design across reverse proxy, OIDC, metrics, backups, and notifications without repeating the same wiring for every service. My goal of this project is helping those who pursue self-hosting as a hobby and face similar issues:

- **Declare a service once**: one definition wires its route, auth, metrics, dashboard, backup, and notifications. No copy-paste per service.
- **Agnostic to a point**: every concern has a provider-neutral contract. I hold an opinion and ship one implementation each, easy to toggle off and replace.
- **Identity and secrets provision themselves**: declare users and groups and they appear in the OIDC provider; each service gets its OIDC client, runtime API keys, and notification token generated at boot and handed to the unit. None of it lands in the Nix store.
- **Remote access is WireGuard, and only WireGuard**: a built-in VPN with per-device provisioning; no other transport.
- **Simple to the point of boring**: on purpose. Plenty is out of scope — private-network-only, single admin, native NixOS services ([the list](#status--scope)).

Flip a few flags and you have, out of the box: **Pocket-ID** (SSO), **tinyauth** (forward-auth), **Homepage** (dashboard), **ntfy** (notifications), and **Prometheus + Alertmanager** (metrics with alerting).

I built this to run my own fleet and I'm sharing it in case it's useful to you. It's opinionated because it only has to suit one person — me. I work on it in spare time, so support is slow, but issues and PRs are welcome.

🚧 **Work in progress** — the honest rough edges:

- One implementation per contract so far (Traefik, Pocket-ID, tinyauth, ntfy). The swap seam exists; the alternatives aren't written.
- Partial automated coverage — a few VM tests, not every concern.
- The bundled service catalog grows as I need things — it won't ever cover everything.
- Docs are young and still filling in.

## Use

```nix
# flake.nix
inputs.selfhost-nix.url = "github:bphenriques/selfhost-nix";
inputs.selfhost-nix.inputs.nixpkgs.follows = "nixpkgs";

# a host (on nixpkgs unstable; secrets are path-based — wire the paths from your backend, e.g. sops-nix)
imports = [ inputs.selfhost-nix.nixosModules.default ];
```

```nix
selfhost = {
  enable = true;
  domain = "home.example.com";

  # Opinionated providers — each a disable-able default behind a neutral contract.
  ingress.traefik.enable           = true;
  auth.oidc.pocket-id.enable       = true;
  auth.forwardAuth.tinyauth.enable = true;
  notify.ntfy.enable               = true;
  monitoring.enable                = true;

  services.miniflux = {
    port = 8081;
    healthcheck.path = "/healthcheck";
    oidc.enable = true;                       # app-level SSO client
    integrations.homepage.enable = true;
    integrations.monitoring.enable = true;
  };
};
```

That single `services.miniflux` block yields a Traefik route at `miniflux.home.example.com`, a Pocket-ID OIDC client, a homepage tile, and a Prometheus healthcheck — no per-service wiring. For a full real-world host wiring a dozen services, see [my dotfiles](https://github.com/bphenriques/dotfiles).

## Status & scope

**Unstable.** The option surface may change without migration notes until at least the next NixOS stable release.

Deliberately out of scope:

- **Public internet exposure.** Defaults assume a private network (LAN/VPN). Putting services on the public internet is a security decision you own — *not* supported out of the box, and not to be taken lightly.
- **Containers as the model.** Bundled services are native NixOS/nixpkgs services; you can register a container you run yourself, but the framework doesn't bundle or orchestrate containers.
- **A module for every service.** Only what nixpkgs supports trivially gets bundled; chasing the long tail isn't worth maintaining across versions (for now).
- **Multi-admin / multi-tenant.** Single admin by design.
- **Non-NixOS.** NixOS modules only — no nix-darwin or other targets.

## Docs

Concepts and the full `selfhost.*` options reference: <https://bphenriques.github.io/selfhost-nix> (built from the module declarations). Build locally with `nix build .#docs` → `result/index.html`.

## Development

```bash
nix fmt                  # format + lint (treefmt)
nix flake check -L       # formatting + package builds + VM tests
nix build .#docs         # docs site → result/index.html
```

[`tests/`](tests/) holds [`nixosTest`](https://nixos.org/manual/nixos/stable/#sec-nixos-tests) VM checks — one concern each, Linux + KVM; run one with `nix build -L .#checks.x86_64-linux.vm-ingress`. Conventions and how to extend it live in [`AGENTS.md`](AGENTS.md).

## Support

Free and open — my small way of giving back to the Nix community. No obligation, ever. If it saved you time and you feel like it, [buy me a coffee](https://buymeacoffee.com/bphenriques) ☕

## License

MIT
