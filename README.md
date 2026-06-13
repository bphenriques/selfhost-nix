# selfhost-nix

Opinionated NixOS modules for a single-admin selfhost: declare a service once and get ingress, auth, secrets, monitoring, homepage, backups, and notifications wired from that one definition.

> **Personal-first and opinionated.** Built for my own fleet and shared as a reference / starting point. The bundled defaults are my choices — Traefik, Pocket-ID, tinyauth, Prometheus, rustic, ntfy. It's open-for-extension, not a swiss-army framework: each default is disable-able behind a neutral contract, and you fork to vary the rest.

## Use

```nix
# flake.nix
inputs.selfhost-nix.url = "github:bphenriques/selfhost-nix";
inputs.selfhost-nix.inputs.nixpkgs.follows = "nixpkgs";

# a host (secrets are path-based — wire the paths from your backend of choice, e.g. sops-nix)
imports = [
  inputs.selfhost-nix.nixosModules.default
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

- **Dashboard tiles** — `integrations.homepage` generates tiles from the registry, grouped by `group`. Set `dashboards.homepage.enable = true` for a managed, out-of-the-box homepage; leave it off and read `dashboards.generatedTiles` into a homepage you own for full control over visuals, tabs, and layout.

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

Each concern is a **provider-neutral contract**: the consuming modules read the contract, never the provider, so a bundled default is swappable for your own where that's sensible (providers) — or *is* the contract where swapping wouldn't be (subsystems). This holds throughout, so the module files don't restate it.

- **Namespace**: concerns group the contract + its swappable impl; on-disk state is prefixed `homelab-`.
- **Providers** (swappable; you enable the bundled default explicitly): `<concern>.<impl>.enable` — `ingress.traefik`, `auth.oidc.pocket-id`, `auth.forwardAuth.tinyauth`, `notify.ntfy`. Disable one and supply your own reading the same contract (`ingress`, `auth.oidc`, `auth.forwardAuth`, `notify`).
- **First-class subsystems** (the tool *is* the contract, no swap): `monitoring` (Prometheus/Alertmanager), `backup` (rustic), `vpn.wireguard`, `storage.smb`, `runtimeSecrets`/`runtimeTemplates` (boot-time secret generation), `resourceControl` (systemd slices).
- **Importing a module changes nothing by itself** — every provider/subsystem is off until enabled explicitly.

## Options

Full reference for every `selfhost.*` option: <https://bphenriques.github.io/selfhost-nix> (generated from the module declarations, published on each push to `main`). Build it locally with `nix build .#options-doc` → `result/index.html`.

## Secrets

Path-based only: every secret option takes a **file path**, never a value, and the framework reads only those paths — it never references a secrets backend directly. Wire the paths from whatever you use ([sops-nix](https://github.com/Mic92/sops-nix), agenix, plain files); nothing secret reaches the Nix store.

## Requirements

- A consumer flake on `nixpkgs` unstable, with `selfhost-nix.inputs.nixpkgs.follows = "nixpkgs"`.
- A secrets backend to supply the file paths (e.g. sops-nix or agenix) — not a hard dependency; the modules reference only paths.

## Tests

[`tests/`](tests/) holds [`nixosTest`](https://nixos.org/manual/nixos/stable/#sec-nixos-tests) VM checks — each boots a guest importing the framework and asserts one concern in isolation. Linux with KVM required.

| Check           | Concern                                                                  |
| --------------- | ------------------------------------------------------------------------ |
| `vm-core`       | registry + runtime-secrets + ntfy provisioning (incl. userless publisher) |
| `vm-ingress`    | Traefik routes a hello-world service end-to-end                          |
| `vm-monitoring` | Prometheus + blackbox health-probe a service                            |

```bash
# run one test, streaming the build/boot log
nix build -L .#checks.x86_64-linux.vm-ingress

# run every check (formatting, package builds, all VM tests)
nix flake check -L

# poke at a live guest: opens the python driver REPL, then `start_all()` and `machine.shell_interact()`
nix run .#checks.x86_64-linux.vm-ingress.driverInteractive
```

The shared base node and the hello-world backend live in [`tests/default.nix`](tests/default.nix); add a concern by dropping a `tests/<name>.nix` beside it and listing it there.

## Development

```bash
nix fmt                                      # format + lint (treefmt: nixfmt, shfmt, mdformat, nufmt, shellcheck, statix, deadnix)
nix flake check -L                           # everything: formatting + package builds + VM tests (see Tests for running one)
nix build .#options-doc                      # build the options site → result/index.html
```

Layout: framework modules in [`modules/nixos/`](modules/nixos) (one concern per file; per-service schema fragments in [`modules/nixos/schemas/`](modules/nixos/schemas)), CLIs in [`packages/`](packages), VM tests in [`tests/`](tests), the options-site generator in [`docs.nix`](docs.nix).

Extending it:

- **Add an option** — declare it in its module with a one-line `description` (descriptions *are* the published docs). If its `default` references other config (e.g. a derived URL), add a `defaultText` so the options site renders without a host config.
- **Add a test** — see the note under [Tests](#tests).
- **Add a provider/subsystem** — new file under `modules/nixos/`, listed in [`modules/nixos/default.nix`](modules/nixos/default.nix); gate everything behind its own `enable` so importing the module changes nothing until turned on.

Docs publishing: [`.github/workflows/docs.yml`](.github/workflows/docs.yml) builds the options site on every push/PR and deploys it to GitHub Pages from `main`. One-time setup: repo **Settings → Pages → Source = "GitHub Actions"**. The site URL and source-link base live in [`docs.nix`](docs.nix) (`repo`) — update them if the repo path differs.

## Support

Free and open — my small way of giving back to the Nix community. No obligation, ever. If it saved you time and you feel like it, [buy me a coffee](https://buymeacoffee.com/bphenriques) ☕

## License

MIT
