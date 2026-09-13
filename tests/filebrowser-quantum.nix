# filebrowser-quantum base: the reconciler declares proxy-auth users at their host-arranged scopes
# over the API, parks unlisted names on the empty default scope, deletes accounts the config no
# longer declares, refuses the admin account to the proxy header, and gates startup on the scopes.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-filebrowser-quantum";

  nodes.machine = {
    imports = [ common ];

    systemd.tmpfiles.rules = [
      "d /srv/files 0755 filebrowser-quantum filebrowser-quantum -"
      "d /srv/files/alice 0700 filebrowser-quantum filebrowser-quantum -"
      "d /srv/files/empty 0555 filebrowser-quantum filebrowser-quantum -"
      "f /run/fbq-admin-password 0400 filebrowser-quantum filebrowser-quantum - deadbeefcafe"
    ];

    services.filebrowser-quantum = {
      enable = true;
      source.path = "/srv/files";
      adminPasswordFile = "/run/fbq-admin-password";
      unlistedScope = "/empty";
      users.alice = {
        scope = "/alice";
        readOnly = false;
      };
      settings.server = {
        listen = "127.0.0.1";
        port = 8095;
      };
    };
  };

  testScript = ''
    import json

    base = "http://127.0.0.1:8095"
    admin = "filebrowser-admin"

    machine.wait_for_unit("filebrowser-quantum.service")
    machine.wait_for_open_port(8095)
    machine.wait_for_unit("filebrowser-quantum-configure.service")

    # Login is rate-limited to a burst of 8 per IP, and the reconciler spends some on its own runs,
    # so the admin token is minted once and reused.
    auth = '-H "Authorization: Bearer %s"' % machine.succeed(
        f'curl -sf -X POST -H "X-Password: deadbeefcafe" "{base}/api/auth/login?username={admin}"'
    ).strip()

    def users():
        return {u["username"]: u for u in json.loads(machine.succeed(f'curl -sf {auth} {base}/api/users'))}

    # alice is a proxy account scoped to her directory, read-write, not admin.
    alice = users()["alice"]
    assert alice["loginMethod"] == "proxy", alice
    assert [s["scope"] for s in alice["scopes"]] == ["/alice"], alice
    assert alice["permissions"]["create"] and alice["permissions"]["modify"], alice
    assert not alice["permissions"]["admin"], alice

    # The admin is a password account, so the proxy header cannot assume it however trusted it looks.
    machine.fail(f'curl -sf -X POST -H "Remote-User: {admin}" "{base}/api/auth/login?username={admin}"')

    # An unlisted name still authenticates (the edge is the gate) but lands on the empty scope.
    machine.succeed(f'curl -sf -X POST -H "Remote-User: mallory" "{base}/api/auth/login?username=mallory"')
    mallory = users()["mallory"]
    assert [s["scope"] for s in mallory["scopes"]] == ["/empty"], mallory
    assert not mallory["permissions"]["create"], mallory

    # Reconciling removes proxy accounts the config does not declare, and keeps the ones it does.
    machine.systemctl("restart filebrowser-quantum-configure.service")
    after = users()
    assert "mallory" not in after, after
    assert "alice" in after, after
    assert admin in after, after

    # The payload the reconciler sends must still exist in the server's own spec.
    spec = json.loads(machine.succeed(f'curl -sf {auth} {base}/swagger/doc.json'))
    contract = json.loads(open("${../modules/nixos/services/filebrowser-quantum/api-contract.json}").read())
    for route in contract["sends"]:
        method, path = route.split(" ", 1)
        assert f"/api{path}" in spec["paths"], f"{path} missing from spec"
        assert method in spec["paths"][f"/api{path}"], f"{route} missing from spec"

    # The scope-check fails the service when a listed scope has no directory.
    machine.systemctl("stop filebrowser-quantum.service")
    machine.succeed("rm -rf /srv/files/alice")
    machine.systemctl("start filebrowser-quantum.service")
    machine.wait_until_fails("systemctl is-active filebrowser-quantum.service")
  '';
}
