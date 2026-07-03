# Introduction

selfhost-nix is a set of opinionated NixOS modules for a single-admin selfhost: declare a service once and
get ingress, authentication, secrets, monitoring, a dashboard tile, backups, and notifications from that
one definition. Each bundled default sits behind a neutral contract you can swap; everything is off until
you enable it.

> ⚠️ **Built for a private network (LAN or VPN)** — nothing here is hardened for the public internet.
> Exposing a service is yours to design and secure, and it is [out of scope](concepts.md#exposure).

> One person's fleet, shared as a reference and starting point. Opinionated and still unstable; you fork to
> vary the rest.

New here? [Getting started](getting-started.md) installs it, [Concepts](concepts.md) explains how it fits
together, [Recipes](recipes.md) wire a service end to end, and the [Options reference](options.md) lists
every `selfhost.*` option.
