# Agent Instructions

Opinionated NixOS modules for a single-admin selfhost. See [README.md](./README.md) for the architecture (contracts, providers, subsystems). This file is the contributor guide: conventions and how to extend.

## Code style

- Idiomatic Nix first, prefer standard NixOS idioms over clever constructs, and match the representation to the semantics:
  - a user toggle → `enable`.
  - a value another module supplies → `nullOr T` with `default = null`, checked with `!= null`.
  - "is X active" that's derivable → check the data (e.g. the registry is non-empty), don't store a flag.
  - No empty-string or null sentinels where a real signal already exists.
- Lean and YAGNI: no speculative abstraction, no over-engineering. Read neighbouring files and match existing patterns before adding new ones.
- Accepted duplication (do not DRY): the per-service configure/reconcile oneshot `serviceConfig` scaffolding, the nushell `wait_ready`/status-check helpers, and the restart-backoff/hardening `serviceConfig` blocks are intentionally repeated per file, not factored into a shared builder/lib. Keep them inline.
- Single-responsibility modules: one concern per file in `modules/nixos/`. Core per-user option fragments live in `modules/nixos/schemas/` (a blessed service instead declares its own per-user surface, see below).
- Gate everything behind an `enable`: importing a module must change nothing until it's turned on.

## Contracts & providers

- A swappable concern is an **interface** + an **implementation**. The interface is `selfhost.<concern>` (the provider-neutral options consumers read). The implementation is `selfhost.<concern>.<impl>`, enabled with `.enable`, and *sets* the interface when active. Consumers read the interface, never the implementation. At most one implementation active per interface. The catalog and rules live in the docs "Contracts & implementations" chapter, so keep it in sync when adding one. Don't restate the model in module headers.
- Subsystems (`monitoring`, `backup`, `storage.smb`) have no split: the tool is the contract.
- Providers register their HTTP service via `selfhost.services.<name>` and any local listening socket via `selfhost.internal.listeningPorts` (a single assertion checks the union for collisions).
- A new provider/subsystem is a file under `modules/nixos/`, imported in `modules/nixos/default.nix`. Gate everything behind its own `enable`. On-disk state is prefixed `homelab-`.
- **Framework vs first-party apps**: the dirs above are framework concerns. A first-party app lives in its own `modules/nixos/services/<name>/` folder, is imported in `default.nix`, and is toggled by **`selfhost.apps.<name>.enable`** (default-off, so importing changes nothing). When enabled it brings up the impl and registers a `selfhost.services.<name>` entry. It owns its whole surface, including any per-user options, which it declares directly on `selfhost.users.*.services.<name>` rather than adding to core's `schemas/`. Core never enumerates an app.
- **Per-user config mirrors the registry** (see the Users docs chapter): a user's per-service config — for *any* service, whether a first-party app or a consumer-registered one — lives at `selfhost.users.<name>.services.<name>` (e.g. `services.wireguard.devices`, `services.jellyfin.enable`), mirroring `selfhost.services.<name>`. `selfhost.apps.<name>` is a deploy shortcut with **no** per-user surface: per-user always belongs to the service, so the path stays put when a service moves between app and consumer wiring. A concern's per-user opt-in mirrors the concern (`selfhost.users.*.auth.oidc`). `extraConfig` (per-user *and* per-service) is the never-read escape hatch **only** for data with no first-class option; the framework must never read either, and a field it needs graduates to a real option. Extending the service-registry submodule with typed options uses `submoduleWith` (it carries `specialArgs`), unlike the plain-`submodule` user type.
- **App enable vs integration are orthogonal**: `selfhost.apps.<name>.enable` runs the app. A separate `enableSelfhostIntegration` (default true) gates framework-derived wiring (e.g. deriving users/storage from `selfhost.users`). A user may run the app with that integration off and wire the cross-cutting concerns themselves. Cross-cutting per-service flags (`forwardAuth`, `oidc`, `integrations.*`) stay independently toggleable on `selfhost.services.<name>`.
- **Compose defaults from concerns, don't hardcode**: an app registers its entry with `mkDefault`, and a cross-cutting toggle defaults to whether its concern is *active*. `forwardAuth.enable = lib.mkDefault (config.selfhost.auth.forwardAuth.url != null)`, notifications default on when a notify provider is enabled, and so on. Sane and composable: enabling a concern lights it up across apps, and the user can still set any of it false.
- **Don't own the consumer's deployment specifics**: an app wires cross-cutting concerns, not *where data lives*. Never re-assert a nixpkgs default (redundant, and a plain assignment turns an overridable option into a fixed one, e.g. miniflux's `createDatabaseLocally`), and never hard-set a deployment option like a database or storage path. Leave it to the nixpkgs default, or set it with `mkDefault` and **read the effective value back** (`config.services.<x>.…`) wherever the framework needs the path, so a consumer relocation is followed by backups/reconcilers rather than silently diverging. App-*owned* state the framework itself manages (keydirs, htpasswd, runtime secrets) is the exception: set those directly.
- **Apps also usable standalone** (e.g. filebrowser, consumed by a non-selfhost host) keep a base module under `services.<name>` exported via `nixosModules.<name>`, and the `selfhost.apps.<name>` wrapper drives that base. Pure apps with no standalone use (e.g. bentopdf) need only the `selfhost.apps.<name>` module and aren't exported.

## Options

- A one-line `description` on every option: descriptions are the published options site.
- Add `defaultText` when a `default` references other config (e.g. a derived URL), so the site renders without a host config.
- Don't mirror upstream: never wrap an existing nixpkgs setting (`services.*`, a `staticConfigOptions.*` key, ...) in a `selfhost.*` option just to re-expose it, since that doubles the docs and the maintenance. Set a sensible default with `lib.mkDefault` (or a freeform `settings`/`extraConfig` passthrough) and let the consumer override the upstream knob directly. Add a dedicated option only for the framework's own surface (contracts, generated config), where a type/validation genuinely earns its keep, or to keep a coherent group of sibling knobs the consumer tunes together discoverable under one namespace (e.g. `monitoring.{retentionTime,retentionSize,scrapeInterval}`), even if one member maps 1:1 to a nixpkgs option.

## Secrets

- Path-based only: options take file paths, never values, and no module references a secrets backend. The consumer wires the paths (sops-nix, agenix, plain files).

## Comments

- Default to none. If the code is clear, it gets no comment. Every comment must earn its place.
- Add one only for what the code can't say: the *why*, a non-obvious constraint, or a cross-file pointer. Never restate clear code, echo an option's name as a label, or repeat architecture that lives in the README.
- When you do comment, one line and succinct: cut every word the sentence survives without.

## Writing style (docs, README, commits)

Prose here is the maintainer's own voice, not an assistant's. Match it and keep the AI tells out.

- **Plain declaratives.** Short sentences that state the point first. No windup intro before the substance ("The major hindrance when...", "It's worth noting that...").
- **No semicolons.** Split into two sentences or use a comma.
- **Em-dashes sparingly.** At most one per paragraph, for a real aside or contrast. Never as a rhythmic device or to bolt a second clause onto every sentence. Prefer a period.
- **Drop the LLM cadence.** No "not just X but Y" framing, no rule-of-three lists padded for rhythm, no bold-lead-in bullets that then stack three qualifiers, no restating one point three ways.
- **No hedge-padding.** Say a thing once. Cut repeated reassurance ("on purpose", "to keep it lean", "lean on purpose").
- Same discipline as comments: if a sentence survives a word's removal, cut the word.

## Docs

- The site (`nix build .#docs`) is an [mdBook](https://rust-lang.github.io/mdBook/) in `docs/`: prose chapters in `docs/src/`, ordered by `docs/src/SUMMARY.md`. `docs.nix` only injects the generated options reference over the `options.md` placeholder, with no theme or CSS to maintain. Preview with `mdbook serve docs`.
- Chapters explain a subsystem's *model* (the why/how), never its options. Options self-document via their `description`. A new chapter is a `docs/src/<name>.md` plus a line in `SUMMARY.md`.
- **Keep code and docs in sync in the same change.** When a module's behaviour or model shifts, update its chapter alongside it: light, succinct, and above all relevant. If an edit doesn't change the model a reader needs, don't write it.

## CLIs (`packages/`)

- `packages/<tool>/` holds standalone selfhost CLIs, exposed via the overlay as `pkgs.selfhost.<tool>`.
- Logic lives in a Nushell `script.nu`. `default.nix` wraps it with the `writeNushellApplication` builder (nu-checks the script at build) + `runtimeInputs`.
- Config-parameterized package overrides (e.g. injecting assets into a third-party package) belong inline in the provider module, not here.

## Tests

- VM integration tests in `tests/` (`nixosTest`), one concern per file, listed in `tests/default.nix`.
- Eval-checking (`nix eval .#checks.<system>.<name>.drvPath`) is cheap and catches option/type/assertion errors. Booting (`nix build .#checks.<system>.vm-*`) catches the integration bugs eval can't. Add a regression test when fixing a real bug.
- A service that needs external infrastructure to boot-test (an SMB server, a live OIDC provider) gets eval coverage only (`smb`, `oidc-rotation` are `*-eval`). Standing up a stub server for a full mount/rotation VM isn't worth the upkeep. Deliberate boundary, not a coverage gap.
