# Bundled apps

`selfhost.apps.<name>.enable` runs a bundled app and wires it into whichever concerns you turned on.
Default-off, and enabling one brings its framework wiring with it. There is no half-wired mode.

[Immich](immich.md), [Jellyfin](jellyfin.md), [FileBrowser Quantum](filebrowser-quantum.md) and the
[\*arr stack](media.md) have their own chapters. Below is what the rest do that their options don't say.
Every option is in the [reference](options.md).

## Radicale

Two routes onto one process. `radicale.<domain>` serves the web UI behind the forward-auth gateway.
`dav.<domain>` serves sync clients on Radicale's own htpasswd, because a phone's calendar app cannot pass a
gateway. `.well-known/caldav` and `/.well-known/carddav` redirect to the root so clients find the server
from the bare hostname.

## CouchDB

`access.model` is `native`: a replicating client speaks HTTP basic auth and nothing else, so no gateway
sits in front. `_up` stays answerable without credentials for the healthcheck. Everything else requires
them.

## Gitea

Accounts and the OIDC auth source go in through the `gitea admin` CLI, which stays stable across versions
in a way the API does not. Service-account SSH keys are the exception and use the admin API, since the CLI
cannot add them.

`ssh.enable` is off because it opens a TCP port. Git over HTTPS works without it, using an access token.

## RomM

Upstream serves the frontend, the downloads and the emulator's cross-origin headers from its own nginx
vhost, so ingress routes to that vhost and RomM's API keeps a separate socket behind it. That is why RomM
registers two ports where other apps register one.

## Open WebUI

Never behind forward-auth: the gateway answers this app's XHR with a redirect it cannot follow and the UI
reload-loops. With an OIDC provider it federates, otherwise it keeps its own accounts.

Unfree in nixpkgs, so it needs `nixpkgs.config.allowUnfree` or a predicate admitting `open-webui`. Every
other bundled app is free software.

## deSEC

Keeps hostnames pointed at the current public IP, for reaching a WireGuard server on a connection whose IP
moves. WireGuard never answers an unauthenticated packet, so a published home IP offers a scanner nothing.
That does not extend to services: publishing an IP and then opening ports to it is a different decision,
and one this project does not help you make.
