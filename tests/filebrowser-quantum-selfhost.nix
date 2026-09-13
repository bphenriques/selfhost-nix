# selfhost.apps.filebrowser-quantum: the adapter on top of the base (tests/filebrowser-quantum.nix
# covers the base itself, tests/filebrowser-quantum-oidc.nix the federated branch). Boots it, because
# every bug this file exists to catch was invisible to eval: the app brought up the access layer
# without its backend, left the required scopes undefined, and advertised a port it did not listen on.
#
# SMB grants stay out of scope for the same reason tests/smb.nix is eval-only: a real bind needs a live
# server. What is covered is the wiring every grant depends on, plus the grant-less user.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-filebrowser-quantum-selfhost";

  nodes.machine = {
    imports = [ common ];

    selfhost = {
      apps.filebrowser-quantum.enable = true;
      # Stands in for a gateway, so the service is routed; the header is what FileBrowser trusts.
      auth.forwardAuth.url = "http://127.0.0.1:9999";
      # Enabled with no storage grants: the case that used to fail the scope check for everyone.
      users.admin.services.filebrowser-quantum = {
        enable = true;
        admin = true;
      };
    };
  };

  testScript =
    { nodes, ... }:
    let
      svc = nodes.machine.selfhost.services.filebrowser-quantum;
      fb = nodes.machine.services.filebrowser-quantum;
    in
    ''
      import json

      machine.wait_for_unit("filebrowser-quantum.service")
      machine.wait_for_unit("filebrowser-quantum-configure.service")

      # The adapter must bring up its own backend and listen where the registry advertises it,
      # or the ingress proxies to a closed port.
      machine.succeed("systemctl is-active filebrowser-quantum.service")
      machine.wait_for_open_port(${toString svc.port}, "${svc.host}")

      # Both scopes exist on disk: the grant-less user's, and the empty one for anyone the gateway
      # lets through who is not listed here. A missing scope fails the service's start-up check.
      machine.succeed("test -d ${fb.source.path}/admin")
      machine.succeed("test -d ${fb.source.path}/.unlisted")

      # Users are derived from selfhost.users, scoped to their own directory.
      pw = machine.succeed("cat ${fb.adminPasswordFile}").strip()
      base = "http://${svc.host}:${toString svc.port}"
      token = machine.succeed(
          f'curl -sf -X POST -H "X-Password: {pw}" "{base}/api/auth/login?username=${fb.adminUsername}"'
      ).strip()
      users = {
          u["username"]: u
          for u in json.loads(machine.succeed(f'curl -sf -H "Authorization: Bearer {token}" {base}/api/users'))
      }
      assert users["admin"]["loginMethod"] == "proxy", users["admin"]
      assert [s["scope"] for s in users["admin"]["scopes"]] == ["/admin"], users["admin"]
      assert users["admin"]["permissions"]["admin"], users["admin"]
    '';
}
