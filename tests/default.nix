# VM integration tests (nixosTest), exposed as flake checks.
{ pkgs, self }:
let
  # nixosTest runs nixpkgs read-only, so apply the overlay here and import the module dir directly:
  # nixosModules.default would set nixpkgs.overlays, which read-only mode rejects.
  pkgs' = pkgs.extend self.overlays.default;

  # Minimal valid selfhost base shared by every test (framework + one required admin user).
  common =
    { config, ... }:
    {
      imports = [ "${self}/modules/nixos" ];
      selfhost = {
        enable = true;
        domain = "test.local";
        users.admin = {
          email = "admin@test.local";
          firstName = "Ada";
          lastName = "Admin";
          groups = [ config.selfhost.groups.admin ];
          services.oidc.enable = false;
        };
      };
    };

  # A hello-world backend registered as a service, reused by the ingress and monitoring tests.
  hello =
    { pkgs, ... }:
    let
      root = pkgs.writeTextDir "index.html" "hello from selfhost\n";
      # `python -m http.server` answers HTTP/1.0, which the blackbox http_2xx module rejects; force 1.1.
      server = pkgs.writeText "hello-server.py" ''
        import http.server, functools
        http.server.SimpleHTTPRequestHandler.protocol_version = "HTTP/1.1"
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory="${root}")
        http.server.ThreadingHTTPServer(("0.0.0.0", 8080), handler).serve_forever()
      '';
    in
    {
      selfhost.services.hello = {
        description = "Hello world";
        port = 8080;
      };
      systemd.services.hello-backend = {
        description = "Hello-world backend";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.python3}/bin/python3 ${server}";
          DynamicUser = true;
        };
      };
    };

  runTest =
    path:
    import path {
      pkgs = pkgs';
      inherit common hello;
    };
in
{
  vm-core = runTest ./core.nix;
  vm-ingress = runTest ./ingress.nix;
  vm-monitoring = runTest ./monitoring.nix;
}
