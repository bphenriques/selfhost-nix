# Introduction

selfhost-nix is a set of opinionated NixOS modules for a single-admin selfhost: declare a service once
and get ingress, authentication, secrets, monitoring, a dashboard tile, backups, and notifications
wired from that one definition.

## How it's organised

Each concern is a **provider-neutral contract**. Consuming modules read the contract, never the
implementation, so a bundled default is swappable for your own — or *is* the contract where swapping
wouldn't make sense:

- **Providers** (swap the default): ingress (Traefik), OIDC (Pocket-ID), forward-auth (tinyauth),
  notifications (ntfy).
- **Subsystems** (the tool is the contract): monitoring, backups, WireGuard, SMB storage, runtime
  secrets, resource control.

Everything is off until you enable it — importing the modules changes nothing on its own.

## Reading these docs

The chapters that follow explain each subsystem's *model* — the why and how behind it. For the exact
knobs, see the [Options reference](options.md), where every `selfhost.*` option is listed with its
type, default, and source location.
