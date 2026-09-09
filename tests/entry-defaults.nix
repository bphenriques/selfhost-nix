# What the registry derives for a single entry from the shape you declare, with no app involved. Each
# case is one entry with one distinguishing field, because these defaults are what decide whether a
# service is routed, probed and counted for port collisions.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  cfg = evalConfig {
    selfhost = {
      monitoring.enable = true;
      # No HTTP backend at all — the case concepts.md invites for a UDP daemon.
      services.udp-daemon.systemdServices = [ "udp-daemon" ];
      # Owns a socket.
      services.owner.port = 9101;
      # Borrows the owner's socket to put a second hostname on one process, as radicale-dav does.
      services.borrower.backend = "owner";
    };
  };

  entry = name: cfg.selfhost.services.${name};
  check =
    name: msg: cond:
    lib.assertMsg cond "${name}: ${msg}";
in
# No backend: nothing to route, nothing to probe, no socket to collide. Probing it used to fail
# evaluation outright with "option port was accessed but has no value defined".
assert check "udp-daemon" "must not be routed" (!(entry "udp-daemon").ingress.enable);
assert check "udp-daemon" "must not be healthchecked" (!(entry "udp-daemon").integrations.monitoring.healthcheck);
assert check "udp-daemon" "owns no backend" (!(entry "udp-daemon").ownsBackend);

# Owns its socket: routed, probed, and the one counted for collisions.
assert check "owner" "must be routed" (entry "owner").ingress.enable;
assert check "owner" "must be healthchecked" (entry "owner").integrations.monitoring.healthcheck;
assert check "owner" "owns its backend" (entry "owner").ownsBackend;

# Borrows one: routed on its own hostname, but the owner is what gets probed and counted, or one
# outage would raise two alerts and one socket would look like two.
assert check "borrower" "must be routed" (entry "borrower").ingress.enable;
assert check "borrower" "must not be healthchecked" (!(entry "borrower").integrations.monitoring.healthcheck);
assert check "borrower" "owns no backend" (!(entry "borrower").ownsBackend);
assert check "borrower" "inherits the owner's port" ((entry "borrower").port == 9101);

# Only the owner reaches the port registry.
assert
  let
    names = map (e: e.name) cfg.selfhost.internal.listeningPorts;
  in
  lib.assertMsg (
    lib.elem "service/owner" names && !(lib.elem "service/borrower" names)
  ) "a borrowed backend must not be registered as its own socket: ${toString names}";

# Forces the scrape configs, which dereferences every healthchecked entry's URL.
assert lib.assertMsg (builtins.deepSeq cfg.services.prometheus.scrapeConfigs true)
  "monitoring must render with these entries registered";
pkgs.runCommand "selfhost-entry-defaults-eval" { } "touch $out"
