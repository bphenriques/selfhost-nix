# selfhost-nix

[![Nix Flakes](https://img.shields.io/badge/Nix-flakes-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)
[![Docs](https://img.shields.io/badge/docs-site-blue)](https://bphenriques.github.io/selfhost-nix)
[![Status](https://img.shields.io/badge/status-unstable-orange)](#out-of-scope)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue)](LICENSE)

Opinionated NixOS flake for single-admin homelab environments that typically repeatedly deal with reverse proxy, authentication/authorization, runtime secrets, backups, monitoring and notifications.

Example:
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

    apps.miniflux = {
      enable = true;
      port = 8081;                           # Register route from `miniflux.home.example.com` to 127.0.1:8081
      healthcheck.path = "/healthcheck";
      access.model = "oidc";
      integrations.homepage.enable = true;
      integrations.monitoring.enable = true;
    };
  };
}
```

For more info check the [docs](https://bphenriques.github.io/selfhost-nix), including the set of [bundled services](https://bphenriques.github.io/selfhost-nix/apps.html) via `selfhost.apps.<name>.enable`.

I created to support my own [homelab](https://github.com/bphenriques/dotfiles) and learn more about self-hosting. It is open by design and if this project intrigues and interests you let me know!


> [!INFO]
> For a more different yet mature approach, consider [`nix-podman-stacks`](https://github.com/Tarow/nix-podman-stacks).

> [!WARNING]
> **Work in progress.** Highly experimental. Will consider a proper release during next NixOS release.

## Out of Scope

- **Public internet exposure**: it has to be a deliberate choice for you. I promote WireGuard.
- **Containers**: very common but it makes networking tricky at times between nixpkgs services and containers.

## Support

I don't expect anything back but if it saved you time and you feel like it, [buy me a coffee](https://buymeacoffee.com/bphenriques) ☕

## AI Disclaimer

I drive the architecture, the design, and the scope. AI has been invaluable to learn and iterate faster. I still take pride in giving my own voice to documentation and tweaking code by hand.

## License

MIT
