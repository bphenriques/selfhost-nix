# Media automation

The `*arr` apps (`apps.radarr`, `apps.sonarr`, `apps.prowlarr`) follow one rule that shapes the whole
design: **the framework wires the plumbing, and never configures a source.**

## The boundary

A media-automation stack has two halves. One is generic infrastructure: ingress, forward-auth, an API key
kept out of the store, notifications, a backup of the library list, and the connections between the tools
(root folders, download clients). The other is *acquisition*: which indexers and trackers to search, which
release qualities to prefer, which categories to file under.

selfhost-nix owns the first half and **ships nothing of the second**. The words *indexer, tracker, quality
profile, custom format* appear nowhere in it. Its plumbing is inert on its own: a download client with no
indexers behind it fetches nothing. So what and where you acquire is entirely yours, kept in your own
(typically private) config, never in the framework.

That makes the apps neutral, general media tooling with legitimate use, and keeps every acquisition
decision and its consequences with the operator.

## What the app wires

`apps.radarr` / `apps.sonarr` register the service (ingress, forward-auth defaulting to the active
provider, admin-group access), generate the API key out of the store and set the app to trust the
forward-auth identity, add a library-list backup hook, and run an **idempotent reconcile** that applies
only what you declare:

- `rootFolders`: library paths (storage-agnostic, and the path must exist).
- `downloadClients`: registered generically via the app's own schema. You name the implementation and
  protocol, so it's never assumed to be torrent (or Transmission). The app connection-tests a client on
  save, so order the reconcile after the client's unit with `configureAfter`.
- `delayProfile`: optional, carrying the protocol preference, so it stays your call with no default.

All three default to empty/none: enabling an app configures nothing you didn't ask for.

`apps.prowlarr` is wiring-only. An indexer manager talks to APIs, not files, so it has no root folders or
download clients. Its indexer list and app-sync are acquisition and live in your config, reading the
apps' `apiKeyFile`.

## What stays yours

- **Indexers / trackers**: Prowlarr, from your private config.
- **Quality profiles / custom formats**: taste, e.g. a recyclarr unit syncing TRaSH guides. The framework
  neither bundles nor schedules it (a network-fetching opinion is not plumbing).
- **Download-client ordering**: `configureAfter = [ "transmission.service" ]` (or your usenet client).
- **Where the data lives**: root-folder paths and the storage mount, as with any service.
