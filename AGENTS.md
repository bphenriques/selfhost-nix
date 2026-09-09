# Agent Instructions

Opinionated NixOS modules for a single-admin selfhost. See [README.md](./README.md) for the architecture (contracts, providers, subsystems). This file is the contributor guide: conventions and how to extend.

## Code style

- Idiomatic Nix first, prefer standard NixOS idioms over clever constructs, and match the representation to the semantics:
  - a user toggle → `enable`.
  - a value another module supplies → declare it with **no default** and ask `options.<path>.isDefined` for presence. Laziness means a reader that only runs once it's set never forces it, and a wrong read says *"option X was accessed but has no value defined"* instead of coercing a `null` into a string somewhere downstream. `auth.oidc.active` is the worked example.
  - `nullOr` only where `null` is a real value in the option's own domain — no category, no backup hook, no delay profile — never as a stand-in for "nobody has supplied this yet". That is a sentinel, and the module system already carries the signal.
  - "is X active" that's derivable → check the data (`isDefined`, a non-empty registry), don't store a flag.
  - No empty-string or null sentinels where a real signal already exists.
- Lean and YAGNI: no speculative abstraction, no over-engineering. Read neighbouring files and match existing patterns before adding new ones.
- Accepted duplication (do not DRY): the per-service configure/reconcile oneshot `serviceConfig` scaffolding, the nushell `wait_ready`/status-check helpers, and the restart-backoff `serviceConfig` blocks are intentionally repeated per file, not factored into a shared builder/lib. Keep them inline. A drifted `RestartSec` is visible and harmless, which is what makes the duplication affordable.
- Hardening is the exception, and used to be on that list: drift in a security invariant is neither visible nor harmless. Every unit this repo defines carries `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, `ProtectKernelTunables`, `ProtectControlGroups`, `RestrictSUIDSGID`, and nothing is added to a unit nixpkgs owns. Drop whichever line conflicts with what the unit does and say why — `RestrictSUIDSGID` denies the setgid bit `selfhost-smb-permissions` needs on its 2770 share roots.
- The filesystem sandbox is opt-in, because it is the part that rots. `ProtectSystem = "strict"` only where the unit runs as root and writes nothing, and `ReadWritePaths` only where every path it writes is a constant this repo owns (`oidc-rotate`, `wireguard-keygen`). A unit running as a service user, or writing where upstream or the consumer can relocate, gets neither: a `ReadWritePaths` that misses a path fails at the write, not at start.
- Single-responsibility modules: one concern per file in `modules/nixos/`. Core per-user option fragments live in `modules/nixos/schemas/` (a blessed service instead declares its own per-user surface, see below).
- Gate everything behind an `enable`: importing a module must change nothing until it's turned on.

## Contracts & providers

- A swappable concern is an **interface** + an **implementation**. The interface is `selfhost.<concern>` (the provider-neutral options consumers read). The implementation is `selfhost.<concern>.<impl>`, enabled with `.enable`, and *sets* the interface when active. Consumers read the interface, never the implementation. At most one implementation active per interface. The model lives in the docs "Concerns & contracts" section (`docs/src/concepts.md`), so keep it in sync when adding one. Don't restate it in module headers.
- Subsystems (`monitoring`, `backup`, `storage.smb`) have no split: the tool is the contract.
- Providers register their HTTP service via `selfhost.services.<name>` and any local listening socket via `selfhost.internal.listeningPorts` (a single assertion checks the union for collisions).
- A new provider/subsystem is a file under `modules/nixos/`, imported in `modules/nixos/default.nix`. Gate everything behind its own `enable`. On-disk state is prefixed `homelab-`.
- **Framework vs first-party apps**: a first-party app lives in `modules/nixos/services/<name>/`, is imported in `default.nix`, and is toggled by **`selfhost.apps.<name>.enable`** (default-off). When enabled it brings up the impl and registers a `selfhost.services.<name>` entry. It owns its whole surface, per-user options included, declaring those on `selfhost.users.*.services.<name>` rather than in core's `schemas/`. Core never enumerates an app. Start from an existing one rather than from this list: `services/bentopdf/` is the shape at its smallest (register, run, nothing else), and `services/radicale/` shows the rest — per-user surface, backup hook, runtime secrets, a reconciler, and a second route onto one backend.
- **Per-user config mirrors the registry** (see the Users chapter): a user's per-service config lives at `selfhost.users.<name>.services.<name>`, mirroring `selfhost.services.<name>`, for any service — app or consumer-registered. `selfhost.apps.<name>` is a deploy shortcut with **no** per-user surface, so the path stays put when a service moves between app and consumer wiring. A concern's per-user opt-in mirrors the concern (`selfhost.users.*.auth.oidc`). `extraConfig`, per-user and per-service, is the never-read escape hatch for data with no first-class option. The framework must never read either, and a field it needs graduates to a real option. Extending the service registry with typed options uses `submoduleWith` (it carries `specialArgs`), unlike the plain-`submodule` user type.
- **App enable vs integration are orthogonal**: `selfhost.apps.<name>.enable` runs the app. A separate `enableSelfhostIntegration` (default true) gates framework-derived wiring (e.g. deriving users/storage from `selfhost.users`). A user may run the app with that integration off and wire the cross-cutting concerns themselves. Cross-cutting per-service settings (`access.*`, `integrations.*`) stay independently settable on `selfhost.services.<name>`.
- **Compose defaults from concerns, don't hardcode**: an app registers its entry with `mkDefault`, and a cross-cutting toggle defaults to whether its concern is *active* (`integrations.notify.enable` follows a notify provider being enabled, and so on). Sane and composable: enabling a concern lights it up across apps, and the user can still set any of it false. An app states *what it is* rather than composing where the framework already does it for you — `access.model = "forwardAuth"` is a fact about the service, and the registry is what withholds its route until a gateway exists.
- **Don't own the consumer's deployment specifics**: an app wires cross-cutting concerns, not *where data lives*. Never re-assert a nixpkgs default (redundant, and a plain assignment turns an overridable option into a fixed one, e.g. miniflux's `createDatabaseLocally`), and never hard-set a deployment option like a database or storage path. Leave it to the nixpkgs default, or set it with `mkDefault` and **read the effective value back** (`config.services.<x>.…`) wherever the framework needs the path, so a consumer relocation is followed by backups/reconcilers rather than silently diverging. App-*owned* state the framework itself manages (keydirs, htpasswd, runtime secrets) is the exception: set those directly.
- **The registry submodule is composed centrally, on purpose**: `services-registry.nix` lists every facet, so adding one touches three spots (schema, implementation, the list). A concern could instead extend the submodule from its own module (which is what per-app files do for `selfhost.users`), but `submoduleWith` + `specialArgs` makes merging from several places fiddly, and a service contract is read far more often than extended.
- **Where a facet lives.** The split is about where a facet is *maintained* — a reader's single view of the contract is the generated options page (`nix build .#docs`), not any one file, so don't optimise the source layout for reading end to end. A facet earns its own file when one of these holds, and is otherwise declared inline in `services-registry.nix`:
  - **Shared across registries.** `metadata`/`homepage` (services + external), `notify`/`storage` (services + tasks). This is why `storage.nix` is a file at one option.
  - **Large enough to navigate alone.** `oidc` (13 options), `monitoring` (5).
  - **Vendor-specific.** It must not leak into the neutral contract, so it sits beside the facet it extends: `schemas/ingress/traefik.nix` next to `schemas/ingress/default.nix`. Keep this surface minimal — ideally empty. A second implementation adds a sibling rather than growing an existing one.
  - Nothing else. `extra.nix` is one services-only option that will not grow, and only stays a file because moving it is not worth the churn.
- **Derived defaults stay together**, in the `config.*` block at the top of `baseServiceModule`, even when the option they default is declared in another file (`integrations.homepage.enable`, `integrations.monitoring.healthcheck`, `ingress.enable`). Reading that block is how you see the composition. A facet file declares its options, it does not compose them.
- **Apps also usable standalone** (e.g. filebrowser, consumed by a non-selfhost host) keep a base module under `services.<name>` exported via `nixosModules.<name>`, and the `selfhost.apps.<name>` wrapper drives that base. Pure apps with no standalone use (e.g. bentopdf) need only the `selfhost.apps.<name>` module and aren't exported.

## Options

- A one-line `description` on every option: descriptions are the published options site.
- Add `defaultText` when a `default` references other config (e.g. a derived URL), so the site renders without a host config.
- **Defining a nixpkgs `attrsOf` option discards its `default`.** Setting one key of `services.<x>.settings` can silently undo everything upstream shipped there, because a `default` only applies while nothing defines the option (definitions merge with each other, never with the default). Check what upstream put there before you set a key, and restate what you would drop with a comment saying why — Open WebUI's telemetry opt-outs are the live example. `tests/upstream-defaults.nix` enforces this across every app.
- Don't mirror upstream: never wrap an existing nixpkgs setting (`services.*`, a `staticConfigOptions.*` key, ...) in a `selfhost.*` option just to re-expose it, since that doubles the docs and the maintenance. Set a sensible default with `lib.mkDefault` (or a freeform `settings`/`extraConfig` passthrough) and let the consumer override the upstream knob directly. Add a dedicated option only for the framework's own surface (contracts, generated config), where a type/validation genuinely earns its keep, or to keep a coherent group of sibling knobs the consumer tunes together discoverable under one namespace (e.g. `monitoring.{retentionTime,retentionSize,scrapeInterval}`), even if one member maps 1:1 to a nixpkgs option.

## Secrets

- Path-based only: options take file paths, never values, and no module references a secrets backend. The consumer wires the paths (sops-nix, agenix, plain files).

## Comments

- Default to none. If the code is clear, it gets no comment. Every comment must earn its place.
- Add one only for what the code can't say: the *why*, a non-obvious constraint, or a cross-file pointer. Never restate clear code, echo an option's name as a label, or repeat architecture that lives in the README.
- When you do comment, one line and succinct: cut every word the sentence survives without.

## Writing style (docs, README)

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
- A CLI that needs config from the module (paths, ports, a data dir) ships as `<tool>-bin` and the module wraps it in a same-named shim that exports the values and `exec`s it (`rustic-manage`, `wg-manage`, `pocket-id-manage`). Keeps the package free of host config while the user still types the plain name.

## Tests

- VM integration tests in `tests/` (`nixosTest`), one concern per file, listed in `tests/default.nix`. `git add` a new file the moment you create it: a flake cannot see an untracked path, and the failure is silent in the worst way — `builtins.attrNames` never forces the value, so every eval check still passes and only the VM job notices.
- Eval-checking (`nix eval .#checks.<system>.<name>.drvPath`) is cheap and catches option/type/assertion errors. Booting (`nix build .#checks.<system>.vm-*`) catches the integration bugs eval can't. Add a regression test when fixing a real bug.
- A service that needs external infrastructure to boot-test (an SMB server, a live OIDC provider) gets eval coverage only (`smb`, `oidc-rotation` are `*-eval`). Standing up a stub server for a full mount/rotation VM isn't worth the upkeep. Deliberate boundary, not a coverage gap.
