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
    # The template's own settings rather than a copy of their shape: a mock drifts from the file
    # consumers actually start from, and then proves only that the mock still evaluates.
    settings = import "${self}/templates/default/private/hosts/myhost/settings.nix";
  };

  host = nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs = { inherit private; };
    modules = [
      self.nixosModules.default
      "${self}/templates/default/hosts/myhost/selfhost.nix"
      {
        boot.isContainer = true; # evaluable without real hardware/bootloader
        system.stateVersion = "25.11";
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
