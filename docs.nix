# selfhost docs site (GitHub Pages): co-located concept chapters (modules/**/*.md) ahead of the
# generated `selfhost.*` options reference. See AGENTS.md "Docs".
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

  conceptChapters = lib.sort (a: b: toString a < toString b) (
    lib.filter (p: lib.hasSuffix ".md" (toString p)) (lib.filesystem.listFilesRecursive (self + "/modules/nixos"))
  );

  optionsHeader = pkgs.writeText "options-reference.md" ''
    # Options reference
  '';

  pandocInputs = lib.concatStringsSep " " (map toString (conceptChapters ++ [ optionsHeader ]));

  # Inlined (not linked) so the page stays a single self-contained file that opens over file://.
  styleHeader = pkgs.writeText "docs-head.html" ''
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <style>
    ${builtins.readFile ./docs.css}
    </style>
  '';
in
pkgs.runCommand "selfhost-docs" { nativeBuildInputs = [ pkgs.pandoc ]; } ''
  mkdir -p $out
  pandoc --standalone --toc --toc-depth=1 --to html --metadata title="selfhost-nix" \
    --include-in-header=${styleHeader} \
    ${pandocInputs} ${optionsDoc.optionsCommonMark} -o $out/index.html
''
