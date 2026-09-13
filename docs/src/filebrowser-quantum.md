# FileBrowser Quantum

`services.filebrowser-quantum` runs [FileBrowser Quantum](https://github.com/gtsteffaniak/filebrowser)
and adds the per-user access model it lacks: proxy-auth or OIDC users, each scoped to a directory with
its own permissions. It owns the whole service, because nixpkgs ships the package without a module. The
base is standalone, usable without the selfhost framework.

Quantum is the maintained successor to the original FileBrowser, which upstream archived on 1 September
2026 at 2.63.23 with no further bug or security fixes.

**Two entry points.** The standalone base is the `nixosModules.filebrowser-quantum` output. The selfhost
adapter ships inside `nixosModules.default` as `selfhost.apps.filebrowser-quantum`.

## Access, not storage

Unchanged from the older module. A user's access is one **scope**, a path under `source.path` *the host
arranged*. The module never creates or mounts directories, only authorizes a name at a path, so it stays
backend-agnostic. A listed scope with no directory fails startup rather than serving an empty view.

The module owns the source definition rather than passing the list through, because scopes are declared
against it and the unlisted scope is a property of the source. Exposing the list raw would split one
setting across two places.

## Auth is the edge's job

Same contract as before. A trusted edge authenticates, sets `authHeader` (default `Remote-User`), and must
strip client-supplied values. The module authorizes the name, never authenticates it.

Quantum auto-creates an authenticated name it does not know, and offers no way to refuse one. Its
`createUser` setting is marked deprecated and always true. Point `unlistedScope` at an empty directory
unless the edge admits only listed users.

## Reconciled over the API

Quantum's CLI creates password accounts only, and refuses to modify an account that logs in another way.
Proxy users cannot be seeded offline, so the reconciler drives the running server. It creates, updates and
deletes: an account the config no longer declares is removed, which also sweeps up the ones unlisted
logins auto-created.

The reconciler authenticates as `adminUsername` through the same proxy header. Quantum grants admin to
whichever name matches it, and never asks a proxy-authenticated actor to confirm a password, so the module
needs no admin credential. That name must never be one the edge can authenticate. An assertion checks it
against the declared users.

Config holds no secrets. Quantum reads every one of them from the environment.

## WebDAV

Quantum serves WebDAV at `/dav`, authenticated by Basic auth carrying a JWT in the password field. A
request has one `Authorization` header, so that cannot coexist with an edge that owns it. The module
disables WebDAV by default. Turn it on only where nothing else claims the header.

## Federated logins

With an OIDC provider active the app federates instead of leaning on the gateway, and proxy auth is
switched off entirely, so no header is trusted under that model. The declared `access.allowedGroups`
are passed to Quantum as `userGroups`, which it enforces itself: under `oidc` the framework leaves
enforcement to the service, so without that the groups would be decorative.

Quantum resolves the issuer at start-up and exits when it cannot reach it. The service therefore
depends on the provider being up at boot, not just at login, and recovers through its restart backoff
rather than starting degraded.
