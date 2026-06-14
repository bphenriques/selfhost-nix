# selfhost docs site (GitHub Pages): the mdBook in docs/ (prose chapters in docs/src/), with the
# generated `selfhost.*` options reference injected over the placeholder at build time.
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
pkgs.runCommand "selfhost-docs" { nativeBuildInputs = [ pkgs.mdbook ]; } ''
  cp -r --no-preserve=mode ${./docs} book
  { echo "# Options reference"; echo; cat ${optionsDoc.optionsCommonMark}; } > book/src/options.md
  mdbook build book -d $out
''
