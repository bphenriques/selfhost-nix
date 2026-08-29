# Internal helpers shared across framework modules.
{ lib }:
{
  # Canonical listen address: the `localhost` alias folds into 127.0.0.1 so the two compare equal.
  normalizeHost = host: if host == "localhost" then "127.0.0.1" else host;

  # A wildcard bind occupies every address on its port, so it overlaps any sibling there.
  isWildcard =
    host:
    lib.elem host [
      "0.0.0.0"
      "::"
    ];

  # Addresses this host binds itself; anything else names a remote target that holds no local socket.
  bindsLocally =
    host:
    lib.elem host [
      "127.0.0.1"
      "localhost"
      "::1"
      "0.0.0.0"
      "::"
    ];

  # From a builtins.groupBy result, the buckets that hold more than one element.
  collisions = lib.filterAttrs (_: group: lib.length group > 1);

  # Every group a policy may name: the canonical set plus any group a user actually holds. A custom
  # group becomes nameable once someone is in it, while typos still fail.
  knownGroups = cfg: lib.unique (lib.attrValues cfg.groups ++ lib.concatMap (u: u.groups) (lib.attrValues cfg.users));
}
