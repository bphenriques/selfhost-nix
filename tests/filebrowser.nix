# filebrowser-multiuser base: the reconciler seeds proxy-auth users at their host-arranged scopes,
# rebuilds only on config change, and the scope-check gates startup. (Covers the standalone base module;
# the selfhost.apps.filebrowser adapter and SMB storage wiring are not yet tested.)
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-filebrowser";

  nodes.machine =
    { config, ... }:
    {
      imports = [ common ];

      environment.systemPackages = [ config.services.filebrowser.package ]; # the CLI, for DB assertions

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
    import re

    db = "/var/lib/filebrowser/filebrowser.db"

    machine.wait_for_unit("filebrowser-configure.service")
    machine.wait_for_unit("filebrowser.service")

    # Inspect the seeded DB with the server stopped: the CLI can't share the sqlite lock with a running
    # server, and the content under test is the reconciler's, not the server's.
    machine.systemctl("stop filebrowser.service")
    machine.succeed(f"filebrowser -d {db} users ls | grep -E 'alice .*/alice'")  # alice at her scope
    cfg = machine.succeed(f"filebrowser -d {db} config cat")
    assert re.search(r"Auth Method:\s+proxy", cfg), cfg  # proxy auth wired
    assert re.search(r"Sign up:\s+false", cfg), cfg      # signup off

    # Reconcile-on-change: restarting with the same config keeps the DB (skip path).
    machine.systemctl("restart filebrowser-configure.service")
    machine.succeed("journalctl -u filebrowser-configure.service | grep -q 'Config unchanged'")

    # The scope-check fails the service when a listed scope has no directory.
    machine.succeed("rm -rf /srv/files/alice")
    machine.systemctl("restart filebrowser.service")
    machine.wait_until_fails("systemctl is-active filebrowser.service")
  '';
}
