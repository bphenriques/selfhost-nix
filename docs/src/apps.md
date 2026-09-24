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

## WireGuard

The way in. Peers are runtime state in `/var/lib/wireguard/peers.json`, owned by `wg-manage`, which
applies every change to the live interface. Adding or removing someone needs no deploy.

A device's tier is its address. `fullAccessSubnet` carves a block out of `clientSubnet` whose devices
reach the LAN; every other address reaches this host on `restrictedPeers` (TCP 80 and 443 by default,
no UDP) and nothing else. The firewall matches those prefixes, so an address is bounded by where it
sits rather than by any list being correct, and a peer nobody registered is still restricted.

```console
$ sudo wg-manage add alice-phone
alice-phone is live at 10.100.0.16.
<QR code>
```

`--full-access` allocates from the full-access block instead, and errors rather than spilling out of it.
`--conf` prints the config instead of a QR, for someone you cannot hand a screen to; what you send is
then a live credential, which the restricted tier is what bounds. Nothing is stored beyond the peer
file, so losing the output means adding again, the same answer as a lost phone.

The server mints the keypair, so a client private key does exist here for as long as it takes to render
the QR. That is a deliberate trade for one command over an enrolment round-trip, and it holds because
the admin already has root on this host. Generate the key on the device and add its public key to the
peer file by hand if you want that property back.

`wg-manage status` is the inventory: address, tier, last handshake, and anything live the file does not
list; the peer file also records when each was added. `remove <name>` cuts a peer and forgets it.
`apply` re-syncs the file onto the interface in both directions, and `wireguard-apply-peers` runs it
whenever the interface appears, so a reboot restores everyone. Anything the three commands do not cover,
edit the file and run `apply`.

Restricted devices reach no DNS either, so `dns` normally names a resolver the device reaches over its
own connection. That resolver has to answer for your domain, since it maps `<subdomain>.<domain>` to the
address the tunnel then carries traffic to. Naming this host instead takes `restrictedPeers.udpPorts = [ 53 ]`.

A restricted client also routes only `lanAccess.serverAddress` rather than the whole subnet, so someone
whose home network overlaps yours keeps their own devices reachable.

The backup hook covers the peer file, not the server private key. Losing the host therefore costs each
device one edited field, its peer `PublicKey`, which the restored file is what makes possible.

## deSEC

Keeps hostnames pointed at the current public IP, for reaching a WireGuard server on a connection whose IP
moves. WireGuard never answers an unauthenticated packet, so a published home IP offers a scanner nothing.
That does not extend to services: publishing an IP and then opening ports to it is a different decision,
and one this project does not help you make.
