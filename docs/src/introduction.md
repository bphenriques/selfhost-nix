# Introduction

selfhost-nix is a set of opinionated NixOS modules for a single-admin selfhost: declare a service once
and get ingress, authentication, secrets, monitoring, a dashboard tile, backups, and notifications
wired from that one definition.

> ⚠️ **Built for a private network (LAN or VPN).** Nothing here is hardened for the public internet.
> Don't take the defaults as internet-safe: if you ever expose a service, that is yours to design and
> secure, and it is [out of scope](ingress.md#exposure). Inform yourself first.

> Built for one person's fleet and shared as a reference and starting point. Opinionated by design and
> still unstable. Each bundled default is swappable behind a neutral contract, and you fork to vary
> the rest.

Each concern is a **provider-neutral contract**: a bundled default you can swap for your own (see
[Contracts & implementations](contracts.md)). Everything is off until you enable it. On top of the
concerns sit a few curated [first-party apps](apps.md) you turn on with one toggle.

New here? [Getting started](getting-started.md) installs and enables it; the chapters after explain each
subsystem's *model*, and the [Options reference](options.md) lists every `selfhost.*` option.
