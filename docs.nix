# selfhost.* options reference as a static HTML site (published to GitHub Pages).
{ pkgs, self }:
let
  inherit (pkgs) lib;
  repo = "https://github.com/bphenriques/selfhost-nix";

  # Full NixOS eval so the framework's options resolve against the real module set; we only read
  # the `selfhost` option subtree, never the config, so no host config is required.
  eval = pkgs.nixos { imports = [ self.nixosModules.default ]; };

  optionsDoc = pkgs.nixosOptionsDoc {
    options = eval.options.selfhost;
    warningsAreErrors = false;
    # Point "Declared in" at the repo source instead of nix-store paths.
    transformOptions =
      opt:
      opt
      // {
        declarations = map (
          decl:
          let
            rel = lib.removePrefix "${toString self}/" (toString decl);
          in
          {
            name = rel;
            url = "${repo}/blob/main/${rel}";
          }
        ) opt.declarations;
      };
  };
in
pkgs.runCommand "selfhost-options-doc" { nativeBuildInputs = [ pkgs.pandoc ]; } ''
  mkdir -p $out
  pandoc --standalone --to html --metadata title="selfhost-nix — options reference" \
    ${optionsDoc.optionsCommonMark} -o $out/index.html
''
