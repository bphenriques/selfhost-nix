# The property the whole forwardAuth model rests on: identity headers reaching the backend come from the
# auth response, never from the client. FileBrowser trusts `Remote-User` as its login, so a header that
# survives a request is an account takeover.
#
# Uses a stub gateway that approves everything and sets no identity, rather than tinyauth: the point is
# what Traefik does with the client's headers, and a real provider cannot complete a login in the VM.
# Setting `auth.forwardAuth.url` directly is the contract working — the interface is what Traefik reads.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-forwardauth-headers";

  nodes.machine =
    { pkgs, ... }:
    let
      # Echoes the identity headers it was handed, so the test can see what survived.
      echo = pkgs.writeText "echo.py" ''
        import http.server, json
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def do_GET(self):
                body = json.dumps({k: v for k, v in self.headers.items() if k.lower().startswith("remote-")}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def log_message(self, *a): pass
        http.server.ThreadingHTTPServer(("127.0.0.1", 8080), H).serve_forever()
      '';
      # Approves every request and returns no Remote-* of its own.
      gate = pkgs.writeText "gate.py" ''
        import http.server
        class H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Length", "0")
                self.end_headers()
            def log_message(self, *a): pass
        http.server.ThreadingHTTPServer(("127.0.0.1", 9999), H).serve_forever()
      '';
    in
    {
      imports = [ common ];

      selfhost = {
        ingress = {
          traefik.enable = true;
          acme = {
            email = "acme@test.local";
            dnsProvider = "cloudflare";
            credentialsEnvFile = toString (pkgs.writeText "acme-env" "CF_DNS_API_TOKEN=dummy\n");
          };
        };
        auth.forwardAuth.url = "http://127.0.0.1:9999";
        services.echo = {
          port = 8080;
          access.model = "forwardAuth";
        };
      };

      systemd.services.echo-backend = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${echo}";
      };
      systemd.services.stub-gate = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${gate}";
      };
    };

  testScript = ''
    machine.wait_for_unit("echo-backend.service")
    machine.wait_for_unit("stub-gate.service")
    machine.wait_for_unit("traefik.service")
    machine.wait_for_open_port(443)

    url = "--resolve echo.test.local:443:127.0.0.1 https://echo.test.local/"
    spoof = "-H 'Remote-User: attacker' -H 'Remote-Groups: admin'"

    machine.wait_until_succeeds("curl -sk " + url, timeout=60)

    # Positive control: the backend does report these headers when they reach it. Without this the
    # assertion below would also pass against a backend that echoes nothing at all.
    direct = machine.succeed(f"curl -s {spoof} http://127.0.0.1:8080/")
    assert "attacker" in direct, f"echo backend does not report Remote-User, so the test proves nothing: {direct}"
    assert "admin" in direct, f"echo backend does not report Remote-Groups: {direct}"

    # Through the gateway: it approves but sets no identity, so neither header may survive.
    seen = machine.succeed(f"curl -sk {spoof} " + url)
    assert "attacker" not in seen, f"client-supplied Remote-User reached the backend: {seen}"
    assert "admin" not in seen, f"client-supplied Remote-Groups reached the backend: {seen}"
  '';
}
