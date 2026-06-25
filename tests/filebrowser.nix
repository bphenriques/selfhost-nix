# filebrowser-multiuser base: the reconciler seeds proxy-auth users at their host-arranged scopes,
# rebuilds only on config change, and the scope-check gates startup. (The SMB selfhost adapter is
# exercised separately — it needs a CIFS server.)
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-filebrowser";

  nodes.machine = {
    imports = [ common ];

    systemd.tmpfiles.rules = [
      "d /srv/files 0755 filebrowser filebrowser -"
      "d /srv/files/alice 0700 filebrowser filebrowser -"
      "d /srv/files/empty 0700 filebrowser filebrowser -"
    ];

    services.filebrowser = {
      enable = true;
      settings = {
        address = "127.0.0.1";
        port = 8095;
        root = "/srv/files";
        database = "/var/lib/filebrowser/filebrowser.db";
      };
    };

    services.filebrowser-multiuser = {
      enable = true;
      unlistedScope = "/empty";
      users.alice = {
        scope = "/alice";
        readOnly = false;
      };
    };
  };

  testScript = ''
    db = "/var/lib/filebrowser/filebrowser.db"

    machine.wait_for_unit("filebrowser-configure.service")
    machine.wait_for_unit("filebrowser.service")

    # alice seeded at her scope; proxy auth wired; no signup / command runner.
    machine.succeed(f"filebrowser -d {db} users ls | grep -E 'alice .*/alice'")
    cfg = machine.succeed(f"filebrowser -d {db} config cat")
    assert '"authMethod": "proxy"' in cfg, cfg
    assert '"signup": false' in cfg, cfg

    # Reconcile-on-change: restarting with the same config keeps the DB (skip path).
    machine.succeed("systemctl restart filebrowser-configure.service")
    machine.succeed("journalctl -u filebrowser-configure.service | grep -q 'Config unchanged'")

    # The scope-check fails the service when a listed scope has no directory.
    machine.succeed("rm -rf /srv/files/alice")
    machine.systemctl("restart filebrowser.service")
    machine.wait_until_fails("systemctl is-active filebrowser.service")
  '';
}
