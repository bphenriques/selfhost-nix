# BentoPDF: the static toolkit binds to localhost only (ingress/forwardAuth is the only public surface).
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-bentopdf";

  nodes.machine = {
    imports = [ common ];
    selfhost.apps.bentopdf.enable = true;
  };

  testScript = ''
    machine.wait_for_unit("bentopdf.service")
    machine.wait_for_open_port(8092)

    machine.succeed("curl -fsS http://127.0.0.1:8092/ > /dev/null")
    machine.succeed("ss -tlnH 'sport = :8092' | grep -q '127.0.0.1:8092'")     # listening on loopback
    machine.fail("ss -tlnH 'sport = :8092' | grep -vqE '127\.0\.0\.1|::1'")    # …and nothing non-loopback
  '';
}
