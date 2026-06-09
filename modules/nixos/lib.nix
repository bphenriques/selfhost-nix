# Internal helpers shared across framework modules.
{ lib }:
{
  # Canonical "host:port" key for backend-collision checks; folds the `localhost` alias into
  # 127.0.0.1 so the two compare equal. Best-effort: wildcard 0.0.0.0 and IPv4/IPv6 overlap
  # are not resolved.
  socket = host: port: "${if host == "localhost" then "127.0.0.1" else host}:${toString port}";

  # From a builtins.groupBy result, the buckets that hold more than one element.
  collisions = lib.filterAttrs (_: group: lib.length group > 1);
}
