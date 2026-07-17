# Agent Instructions

Opinionated NixOS modules for a single-admin selfhost. See [README.md](./README.md) for the architecture (contracts, providers, subsystems); this file is the contributor guide: conventions and how to extend.

## Code style

- Idiomatic Nix first, prefer standard NixOS idioms over clever constructs, and match the representation to the semantics:
  - a user toggle → `enable`;
  - a value another module supplies → `nullOr T` with `default = null`, checked with `!= null`;
  - "is X active" that's derivable → check the data (e.g. the registry is non-empty), don't store a flag.
  - No empty-string or null sentinels where a real signal already exists.
- Lean and YAGNI: no speculative abstraction, no over-engineering. Read neighbouring files and match existing patterns before adding new ones.
- Accepted duplication (do not DRY): the per-service configure/reconcile oneshot `serviceConfig` scaffolding, the nushell `wait_ready`/status-check helpers, and the restart-backoff/hardening `serviceConfig` blocks are intentionally repeated per file, not factored into a shared builder/lib. Keep them inline.
- Single-responsibility modules: one concern per file in `modules/nixos/`; core per-user option fragments in `modules/nixos/schemas/` (a blessed service instead declares its own per-user surface — see below).
- Gate everything behind an `enable`: importing a module must change nothing until it's turned on.

## Contracts & providers

- A swappable concern is an **interface** + an **implementation**: the interface is `selfhost.<concern>` (the provider-neutral options consumers read); the implementation is `selfhost.<concern>.<impl>`, enabled with `.enable`, and *sets* the interface when active. Consumers read the interface, never the implementation. At most one implementation active per interface; the catalog and rules live in the docs "Contracts & implementations" chapter; keep it in sync when adding one. Don't restate the model in module headers.
- Subsystems (`monitoring`, `backup`, `storage.smb`) have no split: the tool is the contract.
- Providers register their HTTP service via `selfhost.services.<name>` and any local listening socket via `selfhost.internal.listeningPorts` (a single assertion checks the union for collisions).
- A new provider/subsystem is a file under `modules/nixos/`, imported in `modules/nixos/default.nix`; gate everything behind its own `enable`. On-disk state is prefixed `homelab-`.
- **Framework vs first-party apps**: the dirs above are framework concerns. A first-party app lives in its own `modules/nixos/services/<name>/` folder, is imported in `default.nix`, and is toggled by **`selfhost.apps.<name>.enable`** (default-off, so importing changes nothing). When enabled it brings up the impl and registers a `selfhost.services.<name>` entry. It owns its whole surface — including any per-user options, which it declares directly on `selfhost.users.*` rather than adding to core's `schemas/`. Core never enumerates an app.
- **Per-user namespace is a 1:1 mirror** (see the Users docs chapter): a per-user option lives at `selfhost.users.<name>.<path>` mirroring its top-level `selfhost.<path>` — an app's at `selfhost.users.*.apps.<name>` (e.g. `apps.wireguard.devices`), a concern's at `selfhost.users.*.<concern>` (e.g. `auth.oidc`). Consumer-owned per-user config that isn't the framework's lives under `selfhost.users.*.extraConfig` (freeform, or typed by the consumer). Don't invent a flat per-user key; mirror the path so it's discoverable.
- **App enable vs integration are orthogonal**: `selfhost.apps.<name>.enable` runs the app; a separate `enableSelfhostIntegration` (default true) gates framework-derived wiring (e.g. deriving users/storage from `selfhost.users`). A user may run the app with that integration off and wire the cross-cutting concerns themselves. Cross-cutting per-service flags (`forwardAuth`, `oidc`, `integrations.*`) stay independently toggleable on `selfhost.services.<name>`.
- **Compose defaults from concerns, don't hardcode**: an app registers its entry with `mkDefault`, and a cross-cutting toggle defaults to whether its concern is *active* — `forwardAuth.enable = lib.mkDefault (config.selfhost.auth.forwardAuth.url != null)`, notifications default on when a notify provider is enabled, etc. Sane and composable: enabling a concern lights it up across apps, and the user can still set any of it false.
- **Don't own the consumer's deployment specifics**: an app wires cross-cutting concerns, not *where data lives*. Never re-assert a nixpkgs default (redundant, and a plain assignment turns an overridable option into a fixed one — e.g. miniflux's `createDatabaseLocally`), and never hard-set a deployment option like a database or storage path. Leave it to the nixpkgs default, or set it with `mkDefault` and **read the effective value back** (`config.services.<x>.…`) wherever the framework needs the path, so a consumer relocation is followed by backups/reconcilers rather than silently diverging. App-*owned* state the framework itself manages (keydirs, htpasswd, runtime secrets) is the exception — set those directly.
- **Apps also usable standalone** (e.g. filebrowser, consumed by a non-selfhost host) keep a base module under `services.<name>` exported via `nixosModules.<name>`; the `selfhost.apps.<name>` wrapper drives that base. Pure apps with no standalone use (e.g. bentopdf) need only the `selfhost.apps.<name>` module and aren't exported.

## Options

- A one-line `description` on every option: descriptions are the published options site.
- Add `defaultText` when a `default` references other config (e.g. a derived URL), so the site renders without a host config.
- Don't mirror upstream: never wrap an existing nixpkgs setting (`services.*`, a `staticConfigOptions.*` key, ...) in a `selfhost.*` option just to re-expose it; that doubles the docs and the maintenance. Set a sensible default with `lib.mkDefault` (or a freeform `settings`/`extraConfig` passthrough) and let the consumer override the upstream knob directly. Add a dedicated option only for the framework's own surface (contracts, generated config) or where a type/validation genuinely earns its keep.

## Secrets

- Path-based only: options take file paths, never values, and no module references a secrets backend. The consumer wires the paths (sops-nix, agenix, plain files).

## Comments

- Default to none. If the code is clear, it gets no comment; every comment must earn its place.
- Add one only for what the code can't say: the *why*, a non-obvious constraint, or a cross-file pointer. Never restate clear code, echo an option's name as a label, or repeat architecture that lives in the README.
- When you do comment, one line and succinct: cut every word the sentence survives without.

## Docs

- The site (`nix build .#docs`) is an [mdBook](https://rust-lang.github.io/mdBook/) in `docs/`: prose chapters in `docs/src/`, ordered by `docs/src/SUMMARY.md`. `docs.nix` only injects the generated options reference over the `options.md` placeholder; no theme or CSS to maintain. Preview with `mdbook serve docs`.
- Chapters explain a subsystem's *model* (the why/how), never its options; options self-document via their `description`. A new chapter is a `docs/src/<name>.md` plus a line in `SUMMARY.md`.
- **Keep code and docs in sync in the same change.** When a module's behaviour or model shifts, update its chapter alongside it: light, succinct, and above all relevant. If an edit doesn't change the model a reader needs, don't write it.

## CLIs (`packages/`)

- `packages/<tool>/` holds standalone selfhost CLIs, exposed via the overlay as `pkgs.selfhost.<tool>`.
- Logic lives in a Nushell `script.nu`; `default.nix` wraps it with `writeShellApplication` + `runtimeInputs`.
- Config-parameterized package overrides (e.g. injecting assets into a third-party package) belong inline in the provider module, not here.

## Tests

- VM integration tests in `tests/` (`nixosTest`), one concern per file, listed in `tests/default.nix`.
- Eval-checking (`nix eval .#checks.<system>.<name>.drvPath`) is cheap and catches option/type/assertion errors; booting (`nix build .#checks.<system>.vm-*`) catches the integration bugs eval can't. Add a regression test when fixing a real bug.
- A service that needs external infrastructure to boot-test (an SMB server, a live OIDC provider) gets eval coverage only (`smb`, `oidc-rotation` are `*-eval`); standing up a stub server for a full mount/rotation VM isn't worth the upkeep. Deliberate boundary, not a coverage gap.
