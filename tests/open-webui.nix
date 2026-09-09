# Open WebUI: the OIDC chain end to end. Pocket-ID provisions the client, the env template renders with
# the real id, and the app starts having read it. Eval proves the wiring exists; only a boot proves the
# ordering holds, which is the part that fails silently — a service reading an unrendered env file just
# starts without OAuth rather than erroring.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-open-webui";

  nodes.machine = {
    imports = [ common ];
    selfhost = {
      mail = {
        host = "smtp.test.local";
        port = 587;
        from = "admin@test.local";
        user = "admin@test.local";
        tls = "starttls";
        passwordFile = builtins.toFile "smtp-pw" "dummy";
      };
      auth.oidc.pocket-id.enable = true;
      apps.open-webui.enable = true;
    };
  };

  testScript = ''
    machine.wait_for_unit("pocket-id.service")
    machine.wait_for_unit("pocket-id-provision-client-open-webui.service")
    machine.wait_for_unit("homelab-runtime-template-open-webui-env.service")
    machine.wait_for_unit("open-webui.service")

    # The template carries the id Pocket-ID actually minted, not the placeholder it was written with.
    rendered = machine.succeed("cat /run/homelab-secrets/templates/open-webui.env")
    assert "PLACEHOLDER" not in rendered, f"template rendered unsubstituted: {rendered}"

    client_id = machine.succeed("cat /var/lib/homelab-oidc/open-webui/id").strip()
    assert f"OAUTH_CLIENT_ID={client_id}" in rendered, f"rendered id does not match the provisioned client: {rendered}"
    assert client_id != "", "no client id was provisioned"

    # The secret never reaches the world-readable store.
    secret = machine.succeed("cat /var/lib/homelab-oidc/open-webui/secret").strip()
    machine.fail(f"grep -rqF -- '{secret}' /nix/store")

    # The app is serving, which means it parsed the environment it was handed.
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:8093/health", timeout=180)
  '';
}
