# selfhost.apps.filebrowser: the adapter on top of the multiuser base (tests/filebrowser.nix covers the
# base itself). Boots it, because every bug this file exists to catch was invisible to eval: the app
# brought up the access layer without its backend, left the required unlisted scope undefined, and
# advertised a port it did not listen on.
#
# SMB grants are out of scope here for the same reason tests/smb.nix stays eval-only — a real bind needs
# a live server. What is covered is the wiring every grant also depends on, plus the grant-less user that
# used to take the whole service down with it.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-filebrowser-selfhost";

  nodes.machine =
    { config, ... }:
    {
      imports = [ common ];

      environment.systemPackages = [ config.services.filebrowser.package ]; # the CLI, for DB assertions

      selfhost = {
        apps.filebrowser.enable = true;
        # Stands in for a gateway, so the service is routed; the header is what FileBrowser trusts.
        auth.forwardAuth.url = "http://127.0.0.1:9999";
        # Enabled with no storage grants: the case that used to fail the scope check for everyone.
        users.admin.services.filebrowser = {
          enable = true;
          admin = true;
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      inherit (nodes.machine.selfhost.services.filebrowser) port host;
      fb = nodes.machine.services.filebrowser.settings;
    in
    ''
      machine.wait_for_unit("filebrowser-configure.service")
      machine.wait_for_unit("filebrowser.service")

      # The adapter must bring up its own backend; enabling the access layer alone leaves nothing serving.
      machine.succeed("systemctl is-active filebrowser.service")

      # It must listen where the registry advertises it, or the ingress proxies to a closed port.
      machine.wait_for_open_port(${toString port}, "${host}")

      # Both scopes exist on disk: the grant-less user's, and the empty one for anyone the gateway lets
      # through who is not listed here. A missing scope fails the service's start-up check.
      machine.succeed("test -d ${fb.root}/admin")
      machine.succeed("test -d ${fb.root}/.unlisted")

      # Users are derived from selfhost.users. Inspect with the server stopped: the CLI cannot share the
      # sqlite lock, and the content under test is the reconciler's.
      machine.systemctl("stop filebrowser.service")
      machine.succeed("filebrowser -d ${fb.database} users ls | grep -E 'admin .*/admin'")
    '';
}
