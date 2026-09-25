# Validates templates/default by instantiating the host the way its own flake.nix does: the real private
# bundle, the real host entry point, and every module it imports. `secrets.nix` is the reason this matters
# — it names `selfhost.*` options too, so stubbing it would let the file consumers start from rot silently.
{
  pkgs,
  self,
  nixpkgs,
}:
let
  template = "${self}/templates/default";

  # What `private.hosts.myhost` resolves to in the template's own private flake, not a copy of its shape.
  private = import "${template}/private/hosts/myhost";

  # Enough of sops-nix for `secrets.nix` to evaluate. This proves the template still names live selfhost
  # options; it says nothing about sops-nix's own interface, which the consumer pins themselves.
  sopsStub =
    { config, lib, ... }:
    let
      pathOpt =
        prefix:
        lib.mkOption {
          type = lib.types.str;
          default = "/run/secrets/${prefix}";
        };
    in
    {
      options.sops = {
        defaultSopsFile = lib.mkOption { type = lib.types.path; };
        age.sshKeyPaths = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        secrets = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options.owner = lib.mkOption {
                  type = lib.types.str;
                  default = "root";
                };
                options.path = pathOpt name;
              }
            )
          );
        };
        templates = lib.mkOption {
          default = { };
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options.owner = lib.mkOption {
                  type = lib.types.str;
                  default = "root";
                };
                options.content = lib.mkOption { type = lib.types.str; };
                options.path = pathOpt "rendered/${name}";
              }
            )
          );
        };
        placeholder = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
        };
      };

      config.sops.placeholder = lib.mapAttrs (n: _: "<PLACEHOLDER:${n}>") config.sops.secrets;
    };

  host = nixpkgs.lib.nixosSystem {
    system = pkgs.stdenv.hostPlatform.system;
    specialArgs = { inherit private; };
    modules = [
      self.nixosModules.default
      sopsStub
      "${template}/hosts/myhost" # the real entry point, imports and all
      { boot.isContainer = true; } # the template's hardware config is a placeholder, by design
    ];
  };

  cfg = host.config;
  failing = map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  inherit (nixpkgs) lib;
in
assert lib.assertMsg (failing == [ ]) "templates/default fires assertions: ${lib.concatStringsSep "; " failing}";
assert lib.assertMsg (cfg.warnings == [ ]) "templates/default warns: ${lib.concatStringsSep "; " cfg.warnings}";
# Nothing else forces this, so a rename in the private bundle would otherwise slip past laziness.
assert lib.assertMsg (
  cfg.sops.defaultSopsFile != null
) "the template no longer wires the private bundle's secrets file";
# `secrets.nix` hands these over, so a renamed option on either side shows up here rather than in a
# consumer's rebuild.
assert lib.assertMsg (lib.hasPrefix "/run/secrets/" cfg.selfhost.mail.passwordFile)
  "the template no longer wires selfhost.mail.passwordFile from its secrets module";
assert lib.assertMsg (lib.hasPrefix "/run/secrets/" cfg.selfhost.ingress.acme.dns01.credentialsEnvFile)
  "the template no longer wires the ACME credentials file from its secrets module";
# Comparing the drvPath forces full evaluation of the template host. Do not interpolate it into the
# output: that carries a string context which makes Nix realise the whole input graph (~11 GiB of
# sources) to build a file holding a path. The other eval checks compare the same way.
assert lib.assertMsg (
  cfg.system.build.toplevel.drvPath != null
) "templates/default must evaluate against the live framework";
pkgs.runCommand "template-default-evaluates" { } "touch $out"
