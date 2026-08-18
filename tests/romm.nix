# RomM: the frontend, the API and the downloads all reach the client through upstream's nginx vhost, so
# what matters here is that the vhost answers on the registered socket, keeps the API on its own one, and
# leaves :80 to the gateway. Pocket-ID provisions the client so the OIDC credentials are rendered into
# RomM's environment; no OIDC login is performed, the heartbeat reports what the app parsed.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-romm";

  nodes.machine = {
    imports = [ common ];

    virtualisation.memorySize = 2048;

    selfhost = {
      # Pocket-ID reads the mail settings unconditionally.
      mail = {
        host = "smtp.test.local";
        port = 587;
        from = "admin@test.local";
        user = "admin@test.local";
        tls = "starttls";
        passwordFile = builtins.toFile "smtp-pw" "dummy";
      };
      auth.oidc.pocket-id.enable = true;
      apps.romm.enable = true;
    };
  };

  testScript = ''
    machine.wait_for_unit("pocket-id.service")
    machine.wait_for_unit("romm.service")
    machine.wait_for_unit("romm-worker.service")
    machine.wait_for_unit("romm-scheduler.service")
    machine.wait_for_open_port(8095)

    machine.succeed("curl -fsS http://127.0.0.1:8095/ | grep -qi '<title>'")            # frontend
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:8095/api/heartbeat | grep -q '\"ENABLED\":true'",   # …API, with OIDC parsed
        timeout=120,
    )

    machine.succeed("ss -tlnH 'sport = :8080' | grep -q '127.0.0.1:8080'")              # API on its own socket
    machine.fail("ss -tlnH 'sport = :80' | grep -q LISTEN")                             # :80 stays with the gateway
  '';
}
