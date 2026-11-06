# Nix is the source of truth for OIDC clients: the base pass removes any client, and any credential
# directory, the config does not declare. This creates both kinds of leftover and asserts they go while
# the declared client stays.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-oidc-provision";

  nodes.machine = {
    imports = [ common ];
    selfhost = {
      mail = {
        host = "smtp.test.local";
        from = "admin@test.local";
        user = "admin@test.local";
        passwordFile = builtins.toFile "smtp-pw" "dummy";
      };
      auth.oidc.pocket-id.enable = true;
      # A registered service with no app behind it: enough to declare one OIDC client.
      services.probe = {
        port = 9001;
        access.model = "oidc";
      };
    };
  };

  testScript = ''
    import json

    machine.wait_for_unit("pocket-id.service")
    machine.wait_for_unit("pocket-id-provision-base.service")
    machine.wait_for_unit("pocket-id-provision-client-probe.service")

    key = machine.succeed("cat /var/lib/homelab-secrets/pocket-id-api-key").strip()
    api = f"curl -fsS http://127.0.0.1:8094/api/oidc/clients -H 'X-API-KEY: {key}'"

    def client_names():
        return {c["name"] for c in json.loads(machine.succeed(api))["data"]}

    # A client Nix never declared, as a rename would leave behind, and its credential directory.
    machine.succeed(
        f"{api} -X POST -H 'Content-Type: application/json' "
        f"""-d '{{"name":"renamed-away","callbackURLs":["https://x/cb"],"pkceEnabled":false,"isPublic":false,"isGroupRestricted":false}}'"""
    )
    machine.succeed("mkdir -p /var/lib/homelab-oidc/renamed-away")
    assert "renamed-away" in client_names()

    machine.systemctl("restart pocket-id-provision-base.service")
    machine.wait_for_unit("pocket-id-provision-base.service")

    names = client_names()
    assert "renamed-away" not in names, f"the undeclared client was not deleted: {names}"
    assert "probe" in names, f"the declared client was deleted: {names}"
    machine.fail("test -e /var/lib/homelab-oidc/renamed-away")
    machine.succeed("test -s /var/lib/homelab-oidc/probe/secret")
  '';
}
