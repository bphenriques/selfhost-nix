# VM integration tests (nixosTest), exposed as flake checks.
{
  pkgs,
  self,
  nixpkgs,
}:
let
  # nixosTest runs nixpkgs read-only, so the overlay and `allowUnfree` (which `apps.open-webui` needs)
  # are applied here rather than by a node: a node setting `nixpkgs.*` is what read-only mode rejects,
  # and that is also why tests import the module dir directly instead of nixosModules.default.
  pkgs' =
    (import nixpkgs {
      inherit (pkgs.stdenv.hostPlatform) system;
      config.allowUnfree = true;
    }).extend
      self.overlays.default;

  # Minimal valid selfhost base shared by every test (framework + one required admin user).
  common =
    { config, ... }:
    {
      imports = [ "${self}/modules/nixos" ];
      selfhost = {
        enable = true;
        ingress.domain = "test.local";
        users.admin = {
          email = "admin@test.local";
          firstName = "Ada";
          lastName = "Admin";
          groups = [ config.selfhost.groups.admin ];
          auth.oidc.enable = false;
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
        displayName = "Hello world";
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

  # Eval-only helper: instantiate the framework + one admin plus the test's module, and hand back `config`
  # for pure-derivation checks (no VM boot). Mirrors `common` for the eval tests.
  evalConfig =
    module:
    (nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        self.nixosModules.default
        {
          boot.isContainer = true;
          system.stateVersion = "25.11";
          nixpkgs.config.allowUnfree = true;
          selfhost = {
            enable = true;
            ingress.domain = "test.local";
            users.admin = {
              email = "admin@test.local";
              firstName = "Ada";
              lastName = "Admin";
              groups = [ "admin" ];
              auth.oidc.enable = false;
            };
          };
        }
        module
      ];
    }).config;

  # Plain nixpkgs with no framework, for checks that compare against what upstream does on its own.
  bareConfig =
    module:
    (nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules = [
        {
          boot.isContainer = true;
          system.stateVersion = "25.11";
          nixpkgs.config.allowUnfree = true;
        }
        module
      ];
    }).config;

  runEval = path: import path { inherit pkgs evalConfig; };
in
{
  vm-core = runTest ./core.nix;
  vm-ingress = runTest ./ingress.nix;
  vm-monitoring = runTest ./monitoring.nix;
  vm-filebrowser = runTest ./filebrowser.nix;
  vm-filebrowser-selfhost = runTest ./filebrowser-selfhost.nix;
  vm-radicale = runTest ./radicale.nix;
  vm-romm = runTest ./romm.nix;
  vm-transmission = runTest ./transmission.nix;
  vm-bentopdf = runTest ./bentopdf.nix;
  vm-gitea = runTest ./gitea.nix;
  vm-forwardauth = runTest ./forwardauth.nix;
  vm-forwardauth-headers = runTest ./forwardauth-headers.nix;
  vm-runtime-templates = runTest ./runtime-templates.nix;
  vm-open-webui = runTest ./open-webui.nix;
  vm-oidc-provision = runTest ./oidc-provision.nix;
  vm-backup = runTest ./backup.nix;
  vm-miniflux = runTest ./miniflux.nix;
  vm-arr = runTest ./arr-vm.nix;
  vm-bazarr = runTest ./bazarr.nix;
  vm-immich = runTest ./immich.nix;
  vm-jellyfin = runTest ./jellyfin.nix;
  vm-shares = runTest ./shares-vm.nix;

  # Eval-only: pure framework derivations/assignments against the live framework (no VM boot).
  template-default = import ./template.nix { inherit pkgs self nixpkgs; };
  cross-service-eval = runEval ./cross-service.nix;
}
# One `app-<name>-eval` per first-party app, so a broken app names itself.
// import ./apps.nix { inherit pkgs evalConfig; }
// {
  wireguard-eval = runEval ./wireguard.nix;
  homepage-eval = runEval ./homepage.nix;
  arr-eval = runEval ./arr.nix;
  smb-eval = runEval ./smb.nix;
  shares-eval = runEval ./shares.nix;
  ports-eval = runEval ./ports.nix;
  entry-defaults-eval = runEval ./entry-defaults.nix;
  upstream-defaults-eval = import ./upstream-defaults.nix { inherit pkgs evalConfig bareConfig; };
  listening-ports-eval = runEval ./listening-ports.nix;
  oidc-rotation-eval = runEval ./oidc-rotation.nix;
}
