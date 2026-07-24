# Validates templates/default by instantiating its host modules with synthetic `private` values and
# stubbed secret paths — proving the template still evaluates against the live framework (and rots loudly
# when an interface changes). It mocks the private *data*, not the private flake input, so no secrets
# backend is needed: the framework only ever wants paths.
{
  pkgs,
  self,
  nixpkgs,
}:
let
  private = {
    sopsSecretsFile = builtins.toFile "secrets.yaml" ""; # unused on the eval path
    settings = {
      domain = "test.local";
      acme.email = "admin@test.local";
      smtp = {
        host = "smtp.test.local";
        port = 587;
        from = "admin@test.local";
        user = "admin@test.local";
        tls = "starttls";
      };
      users.admin = {
        email = "admin@test.local";
        firstName = "Ada";
        lastName = "Admin";
        groups = [ "admin" ];
        auth.oidc.enable = true;
        services.radicale.enable = true;
      };
    };
  };

  host = nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs = { inherit private; };
    modules = [
      self.nixosModules.default
      "${self}/templates/default/hosts/myhost/selfhost.nix"
      {
        boot.isContainer = true; # evaluable without real hardware/bootloader
        system.stateVersion = "24.11";
        # Stand in for secrets.nix: the consumer normally wires these from sops; the framework only needs paths.
        selfhost.mail.passwordFile = "/run/secrets/stub";
        selfhost.ingress.acme.credentialsEnvFile = "/run/secrets/stub";
      }
    ];
  };
in
# Interpolating the drvPath forces full evaluation of the template host without building its closure.
pkgs.runCommand "template-default-evaluates" { } ''
  echo "${host.config.system.build.toplevel.drvPath}" > "$out"
''
