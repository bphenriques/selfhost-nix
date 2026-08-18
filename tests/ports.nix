# internal.listeningPorts (eval-only): the collision guard is transport-aware and knows a wildcard bind
# occupies every address on its port. Pure assertion logic, so no VM.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  fires =
    ports:
    let
      cfg = evalConfig { selfhost.internal.listeningPorts = ports; };
    in
    lib.any (a: !a.assertion && lib.hasInfix "Listening port collisions" a.message) cfg.assertions;

  loopback = name: {
    inherit name;
    port = 9000;
  };
in
assert lib.assertMsg (fires [
  (loopback "a")
  (loopback "b")
]) "two entries on the same socket must collide";

assert lib.assertMsg (fires [
  (loopback "a")
  {
    name = "wildcard";
    host = "0.0.0.0";
    port = 9000;
  }
]) "a wildcard bind must collide with a loopback one on its port";

assert lib.assertMsg (
  !fires [
    (loopback "tcp")
    {
      name = "udp";
      port = 9000;
      protocol = "udp";
    }
  ]
) "different transports on one port must not collide";

assert lib.assertMsg (
  !fires [
    (loopback "loopback")
    {
      name = "lan";
      host = "192.168.1.10";
      port = 9000;
    }
  ]
) "distinct addresses on one port must not collide";

pkgs.runCommand "selfhost-ports-eval" { } "touch $out"
