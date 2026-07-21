# Security

The framework wires the cross-cutting security plumbing. The trust anchors and the host stay yours. Know
the split.

## What the framework does

- **Secrets off the store.** `runtimeSecrets` are generated with `openssl` into `/var/lib/homelab-secrets`
  (root-owned, tight modes), never in the world-readable Nix store. Templates render on tmpfs, and generation
  runs sandboxed (`ProtectSystem = strict`, write scoped to the secrets dir).
- **Durable secret lifecycle.** `regenerateIfMissing` handles disposable random secrets. `generateOnce`
  (+ `generateOnceGuard`) handles data-bound keys, where a key lost while its data survives is left *absent
  and logged*, never silently replaced.
- **The edge is the only public surface.** Services bind `127.0.0.1`, and the reverse proxy fronts them.
  Access is gated by per-service OIDC clients (group-scoped) or `forwardAuth`. The forwardAuth middleware
  sets the identity headers from the auth response, and an assertion refuses `forwardAuth` with no active
  provider.
- **Hardened service units.** Bundled reconcilers and backups run with `ProtectSystem = strict`,
  `NoNewPrivileges`, etc. The notify token reaches non-root consumers via systemd `LoadCredential`.
- **WireGuard, not public exposure.** That is the way in.

## What it will NOT do: your responsibility

- **The root of trust.** It generates *its own* runtime secrets, but any secret *you* supply (sops/age, …) and
  the keys that decrypt them are yours to store, back up, and rotate. The framework never sees your master key.
- **Back up generate-once keys.** A `generateOnce` key is safe from silent replacement, but the framework does
  **not** back it up. Lose it while its data survives and that data is unrecoverable. Copy these out-of-band.
  This is the sharpest edge here.
- **Harden the host.** SSH, firewall baseline, kernel and account hardening, disk encryption: all the host's
  job. The framework hardens *its* service sandboxes, not your machine.
- **Make the exposure decision.** Putting a service on the public internet is your call and your risk, a
  deliberate out-of-scope choice. Nothing here lightens it.
- **Guard a misconfigured edge.** Backends bind localhost so the proxy is the only path in. Keep it that way.
  Any custom edge or proxy-auth you wire must strip client-supplied identity headers, or they are spoofable.

## Key rotation

| Secret | How it rotates |
|---|---|
| OIDC client secrets | Framework-managed: `oidc-rotate [<client>]` (always available) or the opt-in `rotation` timer. It removes the secret and the provider re-mints it. |
| Random per-service secrets (`regenerateIfMissing`) | Delete the file. Regenerated on next activation. |
| Data-bound keys (`generateOnce`) | **Manual and deliberate.** Rotating means re-keying the data it protects, so the framework refuses to auto-rotate (that would brick the data). Remove the secret *together with* its data (or its `.generated` marker) to re-key. |
| Externally-synced secrets (`regenerateIfMissing = false`) | Rotate in your own store. The framework leaves them untouched. |

## Restore & disaster recovery

There is deliberately no restore command. In a real disaster the host is gone, and any wrapper it built with
it, so recovery is a manual runbook you must be able to run from nothing but your backups and your
out-of-band keys. Rehearse it before you need it.

**What the backups contain.** Each `selfhost.backup.targets.<name>` is an independent rustic repository. On the
live host its profile is written to `/etc/rustic/<name>.toml` (repository + `password-file`, plus a
`<name>-secrets.toml` for backend credentials). A snapshot holds only what was staged into that target's tree:
your `bindings` (paths mounted read-only) and each hook's output under `extras/<hook>` (e.g. a Gitea repo copy,
a DB dump). A hook output is *material to replay*, not a live service. Restoring a DB dump means importing it,
not dropping it onto a running database.

**What is NOT in them.** Runtime secrets (`/var/lib/homelab-secrets`) and OIDC credentials are not backed up
unless you explicitly add them as a binding. Two things you must hold **out-of-band**, or the rest is
unrecoverable:

- your **secrets-backend master key** (sops/age). Without it none of the secrets *you* supply decrypt.
- every **`generateOnce` key** (e.g. Pocket-ID's encryption key). Lose one while its data survives and that
  data is gone. This is the sharpest edge in the whole system.

**Recovery order.**

1. **Rebuild the host** and restore the secrets backend, putting the sops/age master key back first.
2. **Restore generate-once keys** from your out-of-band copy into `runtimeSecretsDir` before their services
   start, so they decrypt existing data instead of the guard leaving them absent.
3. **`nixos-rebuild switch`.** Disposable secrets regenerate, and OIDC users and clients re-provision.
4. **Restore data** with rustic into each service's data location, then replay hook outputs (import dumps,
   drop repos back). List and pull a snapshot with `rustic -P <name> snapshots` / `rustic -P <name> restore
   <id> --to <dest>`. On a bare machine, reconstruct the repo string, password, and backend credentials by
   hand from your secrets store first.
