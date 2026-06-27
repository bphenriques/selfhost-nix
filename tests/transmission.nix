# Transmission: the RPC interface binds to localhost only (forwardAuth gates ingress).
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-transmission";

  nodes.machine = {
    imports = [ common ];
    selfhost.apps.transmission.enable = true;
    selfhost.services.transmission.port = 9091; # pin for a deterministic assertion
  };

  testScript = ''
    machine.wait_for_unit("transmission.service")
    machine.wait_for_open_port(9091)

    # RPC reachable on localhost, never on the wire.
    machine.succeed("ss -tlnH 'sport = :9091' | grep -q '127.0.0.1:9091'")
    machine.fail("ss -tlnH 'sport = :9091' | grep -q '0.0.0.0:9091'")
  '';
}
