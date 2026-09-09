# Provisioning is one-way: nothing removes an OIDC client when a service is renamed or dropped, so the
# leftover keeps a live secret. The base pass cannot delete it unattended (it might be hand-made), so it
# reports. A warning nobody proves fires is worth nothing, so this creates both kinds of leftover and
# asserts it names them.
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
    machine.wait_for_unit("pocket-id.service")
    machine.wait_for_unit("pocket-id-provision-base.service")
    machine.wait_for_unit("pocket-id-provision-client-probe.service")

    # Baseline: the declared client is not reported as stale.
    base = machine.succeed("journalctl -u pocket-id-provision-base.service --no-pager")
    assert "does not declare" not in base, f"a declared client was reported stale: {base}"

    # A client Nix never declared, as a rename would leave behind.
    key = machine.succeed("cat /var/lib/homelab-secrets/pocket-id-api-key").strip()
    machine.succeed(
        f"curl -fsS -X POST http://127.0.0.1:8094/api/oidc/clients "
        f"-H 'X-API-KEY: {key}' -H 'Content-Type: application/json' "
        f"""-d '{{"name":"renamed-away","callbackURLs":["https://x/cb"],"pkceEnabled":false,"isPublic":false,"isGroupRestricted":false}}'"""
    )
    # And its credential directory, left on disk by the same rename.
    machine.succeed("mkdir -p /var/lib/homelab-oidc/renamed-away")

    machine.systemctl("restart pocket-id-provision-base.service")
    machine.wait_for_unit("pocket-id-provision-base.service")

    out = machine.succeed("journalctl -u pocket-id-provision-base.service --no-pager")
    assert "renamed-away" in out, f"the stale client was not reported: {out}"
    assert "credential directories with no declared client" in out, f"the stale credential dir was not reported: {out}"

    # Reporting only: it must not have deleted anything.
    machine.succeed("test -d /var/lib/homelab-oidc/renamed-away")
    machine.succeed("systemctl is-active pocket-id-provision-base.service")
  '';
}
