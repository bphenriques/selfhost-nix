# Immich

`apps.immich` runs Immich and reconciles the accounts plus the external libraries that belong to them.
Where photos live stays with the consumer: `mediaLocation`, transcoding, job concurrency and the
machine-learning subsystem are left at their nixpkgs defaults for you to set on `services.immich`.

## Two consumer patterns

Immich stores uploads under its own media location, and can additionally scan directories you already
have. The difference is one option:

```nix
selfhost.users.alice.services.immich.enable = true;                      # upload-only
selfhost.users.bob.services.immich = {
  enable = true;
  libraries = [ { name = "bob-photos"; importPaths = [ "/mnt/photos/bob" ]; } ];
};
```

`libraries` defaults to empty, so an account is upload-only unless you say otherwise, and a deployment
that never uses external libraries declares no paths anywhere. Declared paths become writable to the
service, since Immich writes sidecars and thumbnails beside the originals it imports.

A library's `name` is its reconcile identity. Renaming one creates a second library rather than renaming
the first.

## Accounts

`services.immich.admin` defaults to the user's `isAdmin`, so fleet-level admin carries into Immich
without restating it. `quotaBytes` and `storageLabel` are reconciled on every run, so changing a quota
moves the existing account.

`passwordFile` is a bootstrap credential: applied when the account is created and never reconciled, so a
password changed in the app survives. An account given one is asked to change it on first login.
Accounts without a `passwordFile` get a random password, which is the right default when sign-in is
through OIDC. Without an OIDC provider the service's `access.model` composes to `native`, and each account
needs a `passwordFile` to be reachable.

OIDC only authenticates. `autoRegister` is off, so an OIDC login lands on an account that
`selfhost.users` already declared, matched by email, and a login with no declared account is refused.
That keeps one source of truth for who exists.

The `admin@immich.local` account is separate from all of these. The reconciler authenticates as it to
drive the API, and nothing else uses it.

## Nothing is deleted

The reconcile creates and updates, never removes. Dropping a user or a library from your config leaves
the Immich side untouched, because deleting either would take photos with it. Accounts created outside
the framework are likewise left alone. Removals are a deliberate manual step in the app.

## Backups

Uploaded photos live under Immich's media location, not in your external libraries, so nothing else
covers them. They are far too large to copy through a backup hook, so bind them into a target instead,
which mounts them read-only with no second copy:

```nix
selfhost.backup.targets.<name>.bindings = {
  "/immich/library" = "${config.services.immich.mediaLocation}/library";
  "/immich/upload"  = "${config.services.immich.mediaLocation}/upload";
  "/immich/profile" = "${config.services.immich.mediaLocation}/profile";
};
```

Skip `thumbs/` and `encoded-video/`, which Immich regenerates. If every account is backed by external
libraries, those originals already live in directories you back up separately and there is nothing here
to add.

The app registers no backup hook for the database. Immich writes its own nightly dump to
`<mediaLocation>/backups`, so binding that path picks it up if you want the albums, people and
favourites that a re-scan cannot rebuild.

## Keeping up with Immich

Immich moves API routes across major releases. `api-contract.json` beside the module declares the request
payloads `configure.nu` sends, and the `vm-immich` test asserts them against the server's own
`/api/spec.json`. Immich validates with zod, which strips unknown keys rather than rejecting them, so a
renamed field would otherwise stop being applied with nothing to show for it. Bumping nixpkgs and running
the test is what tells you the reconciler still holds.
