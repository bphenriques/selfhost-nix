# selfhost-nix

Opinionated NixOS modules for a single-admin selfhost: declare a service once and get ingress, auth, secrets, monitoring, homepage, backups, and notifications wired from that one definition.

> **Personal-first and opinionated.** Built for my own fleet and shared as a reference / starting point. The bundled defaults are my choices — Traefik, Pocket-ID, tinyauth, Prometheus, rustic, ntfy — each disable-able behind a neutral contract. Fork to vary the rest.

## Use

```nix
# flake.nix
inputs.selfhost-nix.url = "github:bphenriques/selfhost-nix";
inputs.selfhost-nix.inputs.nixpkgs.follows = "nixpkgs";

# a host (secrets are path-based — wire the paths from your backend of choice, e.g. sops-nix)
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

That single `services.miniflux` block yields a Traefik route at `miniflux.home.example.com`, a Pocket-ID OIDC client, a homepage tile, and a Prometheus healthcheck — no per-service wiring.

## How it works

Each concern is a **provider-neutral contract**: consuming modules read the contract, never the provider, so a bundled default is swappable for your own — or *is* the contract where swapping wouldn't make sense. Importing a module changes nothing until you enable something.

- **Providers** (swap the default): `ingress.traefik`, `auth.oidc.pocket-id`, `auth.forwardAuth.tinyauth`, `notify.ntfy` — disable one and supply your own reading the same contract.
- **Subsystems** (the tool *is* the contract): `monitoring`, `backup`, `vpn.wireguard`, `storage.smb`, `runtimeSecrets`/`runtimeTemplates`, `resourceControl`.

Access is layered across three tiers (`admin`, `users`, `guests`), enforced per service by OIDC group restriction or ForwardAuth — never both. Secrets are path-based: every secret option takes a **file path**, never a value, wired from whatever backend you use ([sops-nix](https://github.com/Mic92/sops-nix), agenix, plain files) — nothing secret reaches the Nix store.

The [docs](https://bphenriques.github.io/selfhost-nix) explain each subsystem's model in depth.

## Docs

Concepts and the full `selfhost.*` options reference: <https://bphenriques.github.io/selfhost-nix> (built from the module declarations, published on each push to `main`). Build locally with `nix build .#docs` → `result/index.html`.

## Requirements

- A consumer flake on `nixpkgs` unstable, with `selfhost-nix.inputs.nixpkgs.follows = "nixpkgs"`.
- A secrets backend for the file paths (sops-nix, agenix, …) — not a hard dependency.

## Development

```bash
nix fmt                  # format + lint (treefmt)
nix flake check -L       # formatting + package builds + VM tests
nix build .#docs         # docs site → result/index.html
```

[`tests/`](tests/) holds [`nixosTest`](https://nixos.org/manual/nixos/stable/#sec-nixos-tests) VM checks — one concern each, Linux + KVM; run one with `nix build -L .#checks.x86_64-linux.vm-ingress`. Conventions and how to extend it (add an option, a concept doc, a provider, a test) live in [`AGENTS.md`](AGENTS.md).

## Support

Free and open — my small way of giving back to the Nix community. No obligation, ever. If it saved you time and you feel like it, [buy me a coffee](https://buymeacoffee.com/bphenriques) ☕

## License

MIT
