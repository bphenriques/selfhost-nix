# Jellyfin

`apps.jellyfin` completes the startup wizard unattended, then reconciles the server name, libraries and
accounts. Transcoding, storage and everything else stays yours to set on `services.jellyfin`.

```nix
selfhost.apps.jellyfin = {
  enable = true;
  libraries = [
    { name = "Movies"; collectionType = "movies"; locations = [ "/mnt/media/movies" ]; }
  ];
};
selfhost.users.alice.services.jellyfin.enable = true;
```

Jellyfin refuses to start with under 2 GiB free in its data directory, and aborts with a core dump rather
than a readable error. Worth knowing before putting `dataDir` on a small partition.

## Everything is merged, never replaced

`branding`, `encoding`, `trickplay` and a user's `policy` are all merged onto whatever Jellyfin currently
holds, then written back only if something changed. That matters most for branding: `LoginDisclaimer` is
where an SSO plugin puts its login button, and replacing the whole object would wipe it on every run.

The same applies to library `locations`, which are reconciled rather than set once. Moving a directory in
your config moves the library.

A library's `name` is its reconcile identity, so renaming one creates a second library.

## Encoding takes exactly one writer

Two mechanisms can own `encoding.xml`, and mixing them is the trap.

`apps.jellyfin.encoding` merges onto what Jellyfin currently holds, so fields you do not name keep their
value. `services.jellyfin.hardwareAcceleration` and `services.jellyfin.transcoding` instead write the
file from a template, and on a server that already has one they do nothing until you also set
`forceEncodingConfig`. That template carries 18 elements while a populated `encoding.xml` runs to over
40, so everything outside it resets to Jellyfin's default, including `TonemappingAlgorithm`,
`PreferSystemNativeHwDecoder` and `EnableDecodingColorDepth10Vp9`, none of which nixpkgs models.

Set both and the file permanently differs from the template, so every restart leaves another
`encoding.xml.backup-<timestamp>` behind. Prefer the nixpkgs options on a fresh install where their
defaults are acceptable, and this one on a server whose settings are worth keeping.

Jellyfin ignores properties it does not recognise, so a misspelled field is dropped without complaint.
`EnableHwEncoding` and `EnableHwDecoding` are the trap worth naming: both are real `TrickplayOptions`
fields, neither exists on `EncodingOptions`, where the equivalents are `EnableHardwareEncoding` and
`HardwareDecodingCodecs`.

## Forward-auth is off

Jellyfin authenticates its own clients, and native apps cannot pass a forward-auth gateway, so it stays on
`access.model = "native"` rather than following the gateway. Set it to `"forwardAuth"` only if every client
you use is a browser.

## Accounts

`passwordFile` is a bootstrap credential: applied when the account is created and never reconciled, so a
password changed in the app survives. Accounts without one get a random password. `policy` is a freeform
passthrough merged into Jellyfin's `UserPolicy`, so anything you do not name keeps its current value.

The `admin` account is separate. The reconciler authenticates as it to drive the API.

## Nothing is deleted

The reconcile creates and updates only. Dropping a library or user from your config leaves the Jellyfin
side untouched, since removing either is destructive. Removals are a deliberate manual step.

## Keeping up with Jellyfin

`api-contract.json` beside the module declares the request payloads `configure.nu` sends, and the
`vm-jellyfin` test asserts them against the server's own `/api-docs/openapi.json`. Jellyfin deserialises
with `System.Text.Json`, which ignores unknown keys rather than rejecting them, so a renamed field would
otherwise stop being applied with nothing to show for it.

`POST /Library/VirtualFolders` takes its name, collection type and paths as query parameters, so library
creation is the one call the contract cannot cover. It fails loudly with a 4xx instead.
