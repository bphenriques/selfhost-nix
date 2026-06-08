# selfhost-nix

Opinionated NixOS modules for a single-admin selfhost: declare a service once and get ingress, auth, secrets, monitoring, homepage, backups, and notifications wired from that one definition.

> **Personal-first and opinionated.** Built for my own fleet and shared as a reference / starting point. The bundled defaults are my choices — Traefik, Pocket-ID, tinyauth, Prometheus, rustic, ntfy. It's open-for-extension, not a swiss-army framework: each default is disable-able behind a neutral contract, and you fork to vary the rest.

## Use

```nix
# flake.nix
inputs.selfhost-nix.url = "github:bphenriques/selfhost-nix";
inputs.selfhost-nix.inputs.nixpkgs.follows = "nixpkgs";

# a host (also import sops-nix — the modules consume config.sops.*)
imports = [
  inputs.selfhost-nix.nixosModules.default
  inputs.sops-nix.nixosModules.sops
];
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

That single `services.miniflux` block yields a Traefik route at `miniflux.home.example.com`, a Pocket-ID OIDC client, a homepage tile, and a Prometheus healthcheck — no per-service wiring.

## Design

- **Service registry** — routing, auth, secrets, and integrations from a single declaration (above).

- **Layered access control** — three tiers (`admin`, `users`, `guests`) enforced via OIDC per-client group restriction or ForwardAuth, never both on the same service.

- **Secret provisioning with systemd ordering** — OIDC clients provisioned from declarations; runtime secrets such as API keys generated at boot. Nothing secret reaches the Nix store.

- **Monitoring registry** — custom extensions for exporters, scrape configs, and alert rules.

- **Reasonable hardening** — leans on NixOS and systemd defaults for service isolation.

- **User provisioning** — a central module configures what each user can access; per-service flags drive OIDC provisioning and configure-time setup:

  ```nix
  selfhost.users.alice = {
    email = "alice@example.com";
    groups = [ config.selfhost.groups.users ];
    services = { miniflux.enable = true; jellyfin.enable = true; };
  };
  ```

## Shape

- **Namespace**: concerns group the contract + its swappable impl; on-disk state is prefixed `homelab-`.
- **Providers** (swappable; you enable the bundled default explicitly): `<concern>.<impl>.enable` — `ingress.traefik`, `auth.oidc.pocket-id`, `auth.forwardAuth.tinyauth`, `notify.ntfy`. Disable one and supply your own reading the same contract (`ingress`, `auth.oidc`, `auth.forwardAuth`, `notify`).
- **First-class subsystems** (the tool *is* the contract, no swap): `monitoring` (Prometheus/Alertmanager), `backup` (rustic), `vpn.wireguard`, `storage.smb`.
- **Importing a module changes nothing by itself** — every provider/subsystem is off until enabled explicitly.

## Secrets

Path-based only: options take **file paths**, never secret values, so nothing secret reaches the Nix store. Wire them from [sops-nix](https://github.com/Mic92/sops-nix) (a required peer — the modules reference `config.sops.{templates,secrets,placeholder}`).

## Requirements

- A consumer flake on `nixpkgs` unstable, with `selfhost-nix.inputs.nixpkgs.follows = "nixpkgs"`.
- `sops-nix` imported alongside `nixosModules.default`.

## License

MIT
