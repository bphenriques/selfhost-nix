# Agent Instructions

Opinionated NixOS modules for a single-admin selfhost. See [README.md](./README.md) for the architecture (contracts, providers, subsystems); this file is the contributor guide — conventions and how to extend.

## Code style

- Idiomatic Nix first — prefer standard NixOS idioms over clever constructs, and match the representation to the semantics:
  - a user toggle → `enable`;
  - a value another module supplies → `nullOr T` with `default = null`, checked with `!= null`;
  - "is X active" that's derivable → check the data (e.g. the registry is non-empty), don't store a flag.
  - No empty-string or null sentinels where a real signal already exists.
- Lean and YAGNI — no speculative abstraction, no over-engineering. Read neighbouring files and match existing patterns before adding new ones.
- Single-responsibility modules — one concern per file in `modules/nixos/`; per-service option fragments in `modules/nixos/schemas/`.
- Gate everything behind an `enable` — importing a module must change nothing until it's turned on.

## Contracts & providers

- Each concern is a **provider-neutral contract**: consumers read the contract, never the provider. This is stated once in README "How it works" — don't restate it in module headers.
- Providers register their HTTP service via `selfhost.services.<name>` and any local listening socket via `selfhost.internal.listeningPorts` (a single assertion checks the union for collisions).
- Naming: providers are `<concern>.<impl>.enable`; on-disk state is prefixed `homelab-`.
- A new provider/subsystem is a file under `modules/nixos/`, imported in `modules/nixos/default.nix`; gate everything behind its own `enable`.

## Options

- A one-line `description` on every option — descriptions are the published options site.
- Add `defaultText` when a `default` references other config (e.g. a derived URL), so the site renders without a host config.
- Don't mirror upstream — never wrap an existing nixpkgs setting (`services.*`, a `staticConfigOptions.*` key, …) in a `selfhost.*` option just to re-expose it; that doubles the docs and the maintenance. Set a sensible default with `lib.mkDefault` (or a freeform `settings`/`extraConfig` passthrough) and let the consumer override the upstream knob directly. Add a dedicated option only for the framework's own surface (contracts, generated config) or where a type/validation genuinely earns its keep.

## Secrets

- Path-based only — options take file paths, never values, and no module references a secrets backend. The consumer wires the paths (sops-nix, agenix, plain files).

## Comments

- Default to none. If the code is clear, it gets no comment — every comment must earn its place.
- Add one only for what the code can't say: the *why*, a non-obvious constraint, or a cross-file pointer. Never restate clear code, echo an option's name as a label, or repeat architecture that lives in the README.
- When you do comment, one line and succinct — cut every word the sentence survives without.

## Docs

- The site (`nix build .#docs`) is an [mdBook](https://rust-lang.github.io/mdBook/) in `docs/`: prose chapters in `docs/src/`, ordered by `docs/src/SUMMARY.md`. `docs.nix` only injects the generated options reference over the `options.md` placeholder — no theme or CSS to maintain. Preview with `mdbook serve docs`.
- Chapters explain a subsystem's *model* (the why/how), never its options — options self-document via their `description`. A new chapter is a `docs/src/<name>.md` plus a line in `SUMMARY.md`.
- **Keep code and docs in sync in the same change.** When a module's behaviour or model shifts, update its chapter alongside it — light, succinct, and above all relevant. If an edit doesn't change the model a reader needs, don't write it.

## CLIs (`packages/`)

- `packages/<tool>/` holds standalone selfhost CLIs, exposed via the overlay as `pkgs.selfhost.<tool>`.
- Logic lives in a Nushell `script.nu`; `default.nix` wraps it with `writeShellApplication` + `runtimeInputs`.
- Config-parameterized package overrides (e.g. injecting assets into a third-party package) belong inline in the provider module, not here.

## Tests

- VM integration tests in `tests/` (`nixosTest`), one concern per file, listed in `tests/default.nix`.
- Eval-checking (`nix eval .#checks.<system>.<name>.drvPath`) is cheap and catches option/type/assertion errors; booting (`nix build .#checks.<system>.vm-*`) catches the integration bugs eval can't. Add a regression test when fixing a real bug.
