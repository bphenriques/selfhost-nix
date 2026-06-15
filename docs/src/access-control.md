# Authentication & access control

Identities live in one place (`users.<name>`), split across three tiers: `admin`, `users`, `guests`.
Exactly one admin user exists; the framework asserts it.

## Two enforcement points

A service is gated one of two ways, never both:

- **OIDC** (`oidc.enable`): the app is its own OIDC client; users sign in at the provider (Pocket-ID by
  default) and the app restricts by group.
- **Forward-auth** (`forwardAuth.enable`): the ingress gateway authenticates the request before it
  reaches an app that has no SSO of its own.

`access.allowedGroups` names who may enter (empty = any authenticated user). A service that sets groups
but enables neither mechanism enforces nothing itself; the framework warns.

## Provisioning & credential delivery

OIDC clients, users, and groups are provisioned from the declarations at boot. Each client's id/secret
land in a per-client tmpfs directory and reach the consuming service via systemd `LoadCredential` or a
supplementary group, ordered after the provisioning unit. Nothing secret reaches the Nix store.
