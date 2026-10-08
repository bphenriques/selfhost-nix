# RomM: the frontend, the API and the downloads all reach the client through upstream's nginx vhost, so
# what matters here is that the vhost answers on the registered socket, keeps the API on its own one, and
# leaves :80 to the gateway. `settings` is checked through what RomM parsed, since a store-linked
# config.yml it cannot write is the whole point. Pocket-ID provisions the client so the OIDC credentials
# are rendered into RomM's environment; no OIDC login is performed, the heartbeat reports what it parsed.
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
      apps.romm = {
        enable = true;
        settings.system.platforms.megadrive = "genesis";
      };
      services.romm.access.allowedGroups = [
        "users"
        "admin"
      ];
    };
  };

  testScript = ''
    machine.wait_for_unit("pocket-id.service")
    machine.wait_for_unit("romm.service")
    machine.wait_for_unit("romm-worker.service")
    machine.wait_for_unit("romm-scheduler.service")
    machine.wait_for_open_port(8095)

    machine.succeed("curl -fsS http://127.0.0.1:8095/ | grep -i '<title>' >/dev/null")            # frontend
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:8095/api/heartbeat | grep '\"ENABLED\":true' >/dev/null",   # …API, with OIDC parsed
        timeout=120,
    )

    machine.succeed("ss -tlnH 'sport = :8080' | grep '127.0.0.1:8080'")              # API on its own socket
    machine.fail("ss -tlnH 'sport = :80' | grep LISTEN")                             # :80 stays with the gateway

    cfg = machine.succeed("curl -fsS http://127.0.0.1:8095/api/config")
    assert '"PLATFORMS_BINDING":{"megadrive":"genesis"}' in cfg, cfg                 # settings reached RomM
    assert '"CONFIG_FILE_WRITABLE":false' in cfg, cfg                                # …from the store, read-only

    # Federated, so the wizard's local-admin form is off even with no admin user yet.
    machine.succeed("curl -fsS http://127.0.0.1:8095/api/heartbeat | grep '\"SHOW_SETUP_WIZARD\":false' >/dev/null")

    # One seat per allowed group, and no seat for a group the provider refuses: RomM 403s it rather
    # than falling back to its non-admin role.
    env = machine.succeed("systemctl show romm.service -p Environment")
    assert "OIDC_ROLE_ADMIN=admin" in env, env
    assert "OIDC_ROLE_EDITOR=users" in env, env
    assert "OIDC_ROLE_VIEWER" not in env, env
  '';
}
