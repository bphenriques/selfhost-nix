# Agent Instructions

Opinionated NixOS modules for a single-admin selfhost. See [README.md](./README.md) for the architecture (contracts, providers, subsystems) and [Development](./README.md#development) for layout and how to extend.

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

- Each concern is a **provider-neutral contract**: consumers read the contract, never the provider. This is stated once in README "Shape" — don't restate it in module headers.
- Providers register their HTTP service via `selfhost.services.<name>` and any local listening socket via `selfhost.internal.listeningPorts` (a single assertion checks the union for collisions).
- Naming: providers are `<concern>.<impl>.enable`; on-disk state is prefixed `homelab-`.

## Options

- A one-line `description` on every option — descriptions are the published options site.
- Add `defaultText` when a `default` references other config (e.g. a derived URL), so the site renders without a host config.

## Secrets

- Path-based only — options take file paths, never values, and no module references a secrets backend. The consumer wires the paths (sops-nix, agenix, plain files).

## Comments

- Only when they add what the code can't — the *why*, a non-obvious constraint, or a cross-file pointer.
- Never restate what a clear variable + an intuitive expression already say; never echo an option's name as a section label; don't repeat architecture that lives in the README.
- One line where possible; clear yet brief.

## CLIs (`packages/`)

- `packages/<tool>/` holds standalone selfhost CLIs, exposed via the overlay as `pkgs.selfhost.<tool>`.
- Logic lives in a Nushell `script.nu`; `default.nix` wraps it with `writeShellApplication` + `runtimeInputs`.
- Config-parameterized package overrides (e.g. injecting assets into a third-party package) belong inline in the provider module, not here.

## Tests

- VM integration tests in `tests/` (`nixosTest`), one concern per file, listed in `tests/default.nix`.
- Eval-checking (`nix eval .#checks.<system>.<name>.drvPath`) is cheap and catches option/type/assertion errors; booting (`nix build .#checks.<system>.vm-*`) catches the integration bugs eval can't. Add a regression test when fixing a real bug.
