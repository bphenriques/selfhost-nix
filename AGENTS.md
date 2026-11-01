# Agent Instructions

Opinionated NixOS modules for a single-admin selfhost. Architecture is in [README.md](./README.md) and the docs. This file is the rules.

## Code style

- Idiomatic Nix. Match the representation to the semantics:
  - A user toggle is `enable`.
  - A value another module supplies has **no default**. Test presence with `options.<path>.isDefined` (`auth.oidc.active` is the example).
  - `nullOr` only where `null` is a real value in the domain (no category, no backup hook), never as "not supplied yet".
  - Derive "is X active" from the data (`isDefined`, a non-empty registry). Don't store a flag.
- YAGNI. Read neighbouring files and match their patterns.
- Accepted duplication, keep inline: per-service configure/reconcile `serviceConfig` scaffolding, the nushell `wait_ready`/status helpers, restart-backoff blocks.
- Hardening is not duplication to tolerate drift in. Every unit this repo defines carries `ProtectHome`, `PrivateTmp`, `NoNewPrivileges`, `ProtectKernelTunables`, `ProtectControlGroups`, `RestrictSUIDSGID`. Drop a line only where it conflicts, and say why. Add nothing to units nixpkgs owns.
- Filesystem sandbox is opt-in. `ProtectSystem = "strict"` only for a root unit that writes nothing, or writes only constant paths this repo owns (`oidc-rotate`, `wireguard-keygen`). A missed `ReadWritePaths` fails at the write, not at start.
- One concern per file in `modules/nixos/`. Core per-user fragments live in `schemas/`.
- Importing a module changes nothing until its own `enable`. There is no framework-wide `enable`.

## Contracts & providers

- A swappable concern is an interface (`selfhost.<concern>`, what consumers read) plus an implementation (`selfhost.<concern>.<impl>.enable`, which sets the interface). At most one implementation active. The model is in `docs/src/concepts.md`. Keep it in sync, don't restate it in headers.
- Split a concern only when a second implementation exists. Until then it is a subsystem, where the tool is the contract (`monitoring`, `backup`, `storage.smb`).
- Register HTTP services via `selfhost.services.<name>` and every local socket via `selfhost.internal.listeningPorts`.
- A new provider or subsystem is a file under `modules/nixos/`, imported in `default.nix`. On-disk state is prefixed `homelab-`.
- First-party apps live in `modules/nixos/services/<name>/`, toggled by `selfhost.apps.<name>.enable` (default off). An app runs the impl, registers its `selfhost.services.<name>` entry, and declares its own per-user options on `selfhost.users.*.services.<name>`. Core never enumerates an app. Smallest example: `services/bentopdf/`. Full example: `services/radicale/`.
- Per-user config mirrors the registry: `selfhost.users.<name>.services.<service>`, for apps and consumer-registered services alike. `selfhost.apps.<name>` has no per-user surface. A concern's per-user opt-in mirrors the concern (`selfhost.users.*.auth.oidc`).
- `extraConfig` (per-user and per-service) is never read by the framework. A field it needs becomes a real option.
- Extend the service registry with `submoduleWith` (it carries `specialArgs`).
- An app is curated: `enable` brings the app and all its wiring, with no flag for half. An app with a framework-free use gets a standalone base module under `services.<name>`, exported via `nixosModules.<name>` (`filebrowser-quantum`).
- Compose defaults from concerns. Register entries with `mkDefault`. A cross-cutting toggle defaults to whether its concern is active. An app states facts (`access.model`) and lets the registry compose.
- Don't own deployment specifics. Never re-assert a nixpkgs default or hard-set a database or storage path. Use `mkDefault` and read the effective value back (`config.services.<x>.…`). State the framework itself manages (keydirs, htpasswd, runtime secrets) is set directly.
- `services-registry.nix` lists every facet. A facet gets its own file only when shared across registries, large (`oidc`), or vendor-specific (`schemas/ingress/traefik.nix`, kept minimal).
- Derived defaults live together in the `config.*` block at the top of `baseServiceModule`. Facet files declare, they don't compose.

## Options

- One-line `description` on every option. Detail goes in a docs chapter.
- `defaultText` whenever a `default` references other config.
- Defining a nixpkgs `attrsOf` option discards its `default`. Before setting a key, check upstream's default and restate what you'd drop, with a comment. `tests/upstream-defaults.nix` enforces this.
- Don't wrap nixpkgs settings in `selfhost.*` options. Set `mkDefault` and let the consumer override upstream. Exceptions: the framework's own surface, or a group of sibling knobs tuned together.

## Secrets

- Options take file paths, never values. No module references a secrets backend.

## Comments

- Default to none. Comment only what the code can't say: the why, a non-obvious constraint, a cross-file pointer.
- One line. Never restate code or repeat architecture from the docs.

## Writing style (docs, README)

- Plain declaratives, point first. No windup.
- No semicolons. No em-dashes.
- No LLM cadence: no "not just X but Y", no padded threes, no restating a point.
- Say it once. Cut every word the sentence survives without.

## Docs

- `nix build .#docs` builds the mdBook in `docs/`. Chapters in `docs/src/`, ordered by `SUMMARY.md`. `docs.nix` injects the options reference. Preview with `mdbook serve docs`.
- Chapters explain a subsystem's model, never its options.
- Update the chapter in the same change as the behaviour.

## CLIs (`packages/`)

- `packages/<tool>/` holds CLIs, exposed as `pkgs.selfhost.<tool>`. Logic in a Nushell `script.nu`, wrapped by `writeNushellApplication`.
- A CLI needing module config ships as `<tool>-bin`, and the module wraps it in a same-named shim that exports the values (`rustic-manage`, `wg-manage`).
- Config-parameterised overrides of third-party packages stay inline in the provider module.

## Tests

- VM tests in `tests/`, one concern per file, listed in `tests/default.nix`. `git add` new files at once: a flake can't see untracked paths, and only the VM job notices.
- Eval checks catch option and assertion errors. VM tests catch integration bugs. Add a regression test when fixing a real bug.
- After restarting a `simple` service, wait for its port, not its unit: the unit counts as started before the service is ready.
- Services needing external infrastructure (SMB server, live OIDC) get eval coverage only.
