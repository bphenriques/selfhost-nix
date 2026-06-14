# Runtime secrets & templates

Some secrets shouldn't live in the Nix store or even your secrets backend — API keys a service mints for
itself, encryption keys generated once. `runtimeSecrets` generates these at boot (`openssl rand`) into a
persistent directory (include `runtimeSecretsDir` in backups), regenerating if missing — or failing, for
values you sync externally.

## Templates

A config file that must embed a secret references it by an opaque `runtimePlaceholder` (or `oidcPlaceholder`),
never the value. `runtimeTemplates` renders the file on each boot into tmpfs, substituting placeholders for
the real file contents, so the rendered secret never reaches the store. Both wire `restartUnits` so consumers
restart when a value or template changes.
