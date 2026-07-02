# Runtime secrets & templates

Some secrets shouldn't live in the Nix store or even your secrets backend: API keys a service mints for
itself, encryption keys generated once. `runtimeSecrets` generates these at boot (`openssl rand`) into a
persistent directory (include `runtimeSecretsDir` in backups).

## Lifecycle

A missing file is handled by one of three policies:

- **`regenerateIfMissing = true`** (default) — regenerate. Fine for values any consumer re-reads (API keys).
- **`regenerateIfMissing = false`** — leave absent and log; you sync/seed it externally (sops, manual).
- **`generateOnce = true`** — generate on first boot, then *never* regenerate. For **data-bound** secrets
  (an encryption key): a new value would orphan what it protects, so a later loss is restored from backup,
  not silently replaced. Whether that data still exists is read from `generateOnceGuard` (point it at the
  data dir) or, by default, a `.generated` marker beside the secret. (Supersedes `regenerateIfMissing`.)

## Rotation

Rotation is a deliberate op: **remove the value and restart its generator** — the value regenerates and the
declared consumers (`restartUnits`, or `dependentServices` for OIDC clients) restart to pick it up. OIDC
client secrets have a wrapper, `oidc-rotate [<client>]`, and an opt-in timer
(`selfhost.auth.oidc.rotation.{enable,schedule,notifyTopic}`, default weekly @ 03:00, alert on failure).

A `generateOnce` secret resists this by design — while its guarded data (or `.generated` marker) survives,
`rm` + restart leaves it absent and fails loudly rather than replacing data-bound material. Rotating one
deliberately means removing that data (or marker) too.

## Templates

A config file that must embed a secret references it by an opaque `runtimePlaceholder` (or `oidcPlaceholder`),
never the value. `runtimeTemplates` renders the file on each boot into tmpfs, substituting placeholders for
the real file contents, so the rendered secret never reaches the store. Both wire `restartUnits` so consumers
restart when a value or template changes.
