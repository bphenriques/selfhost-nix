# Ingress concern: Traefik routes a registered service end-to-end.
# TLS uses Traefik's fallback self-signed cert (ACME can't run in the VM), so curl with -k.
{
  pkgs,
  common,
  hello,
}:
pkgs.testers.runNixOSTest {
  name = "selfhost-ingress";

  nodes.machine = {
    imports = [
      common
      hello
    ];
    selfhost.ingress = {
      traefik.enable = true;
      acme = {
        email = "acme@test.local";
        dnsProvider = "cloudflare";
        credentialsEnvFile = toString (pkgs.writeText "acme-env" "CF_DNS_API_TOKEN=dummy\n");
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("hello-backend.service")
    machine.wait_for_unit("traefik.service")
    machine.wait_for_open_port(80)
    machine.wait_for_open_port(443)

    # http is redirected to https
    machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost/ | grep -qE '30[18]'")

    # the service is reachable through Traefik's router
    machine.wait_until_succeeds(
        "curl -sk --resolve hello.test.local:443:127.0.0.1 https://hello.test.local/ | grep -q 'hello from selfhost'",
        timeout=60,
    )
  '';
}
