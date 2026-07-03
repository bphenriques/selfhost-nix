# Forward-auth: a forwardAuth-gated route challenges an unauthenticated request (tinyauth → not 200, never
# reaches the backend). Needs the real auth stack — Pocket-ID provisions tinyauth's client, Traefik carries
# the middleware.
{
  pkgs,
  common,
  hello,
}:
pkgs.testers.runNixOSTest {
  name = "selfhost-forwardauth";

  nodes.machine = {
    imports = [
      common
      hello
    ];
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
      auth.forwardAuth.tinyauth.enable = true;
      ingress = {
        traefik.enable = true;
        acme = {
          email = "acme@test.local";
          dnsProvider = "cloudflare";
          credentialsEnvFile = toString (pkgs.writeText "acme-env" "CF_DNS_API_TOKEN=dummy\n");
        };
      };
      # Gate the hello backend at the edge.
      services.hello.forwardAuth.enable = true;
    };
  };

  testScript = ''
    machine.wait_for_unit("pocket-id.service")
    machine.wait_for_unit("tinyauth.service")
    machine.wait_for_unit("traefik.service")
    machine.wait_for_unit("hello-backend.service")
    machine.wait_for_open_port(443)

    url = "--resolve hello.test.local:443:127.0.0.1 https://hello.test.local/"

    # Unauthenticated: the middleware consults tinyauth and the request never reaches hello. (In-VM tinyauth
    # returns 500 rather than a clean 302 — it can't resolve the OIDC issuer without DNS — but the route is
    # gated, which is the property under test: drop the middleware and hello would answer 200.)
    status = machine.wait_until_succeeds(
        "curl -sk -o /dev/null -w '%{http_code}' " + url, timeout=60
    ).strip()
    assert status != "200", f"forwardAuth did not gate the route (got {status})"
    machine.fail("curl -sk " + url + " | grep -q 'hello from selfhost'")
  '';
}
