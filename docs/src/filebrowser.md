# FileBrowser (multi-user)

`services.filebrowser-multiuser` adds the per-user access model [FileBrowser](https://filebrowser.org)
lacks: proxy-auth users, each scoped to a directory with its own permissions, reconciled into its
database. It sits on `services.filebrowser` (NixOS) and reads root/branding/view from there. This base
module is standalone, usable without the selfhost framework (a non-selfhost host drives it directly).

**Two entry points.** The standalone base is the `nixosModules.filebrowser-multiuser` output. The selfhost
adapter ([below](#selfhost-integration)) ships inside `nixosModules.default`.

## Access, not storage

A user's access is one **scope**, a path under the FileBrowser root *the host arranged*. The module never
creates or mounts directories, only authorizes a name at a path. So it stays backend-agnostic, and a listed
scope with no directory fails startup rather than serving an empty view.

## Auth is the edge's job

FileBrowser runs in proxy-auth mode trusting `authHeader` (default `Remote-User`): a trusted edge
(forwardAuth, a reverse-proxy's BasicAuth) authenticates, sets the header, and must strip client-supplied
values. The module authorizes the name, never authenticates it. An authenticated name not in `users` is
auto-created from `unlistedScope`/`unlistedPermissions`. Point `unlistedScope` at an empty directory unless
the edge admits only listed users.

## Declarative database

The DB is a derived artifact: a reconciler rebuilds it from the declared config whenever that config changes
(a plain reboot keeps it), so removed users drop and nothing drifts. It disables signup and the command
runner. Don't pair it with stateful FileBrowser features.

## Selfhost integration

On a selfhost host, `selfhost.apps.filebrowser.enable` runs the app (and the base above). Its
`enableSelfhostIntegration` (default on) exposes a per-user opt-in at `selfhost.users.<name>.services.filebrowser`:
SMB `storage` grants (`ro`/`rw`) assembled into the user's scope, with the service registered behind the
active forwardAuth. Turn it off to wire users, storage, and auth yourself.
