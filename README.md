# selfhost-nix

Opinionated NixOS modules for a single-admin selfhost: declare a service once and get reverse proxy + TLS, single sign-on, a dashboard, metrics with alerting, backups, and notifications wired from that one definition.

Flip a few flags and you have, integrated out of the box: **Pocket-ID** (SSO), **tinyauth** (forward-auth), **WireGuard** (VPN), **Homepage** (dashboard), **ntfy** (notifications), and **Prometheus + Alertmanager** (metrics with alerting) — each swappable behind a neutral contract.

> **Personal-first, community-second.** Built for my own fleet and shared as a reference and starting point. My availability is limited, so support is best-effort — but issues and PRs are welcome.

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
