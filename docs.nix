# selfhost docs site (GitHub Pages, mdBook): an intro, the co-located concept chapters
# (modules/**/*.md), and the generated `selfhost.*` options reference. See AGENTS.md "Docs".
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

  # Concept chapters: every *.md co-located with a module, titled by its first heading.
  chapterTitle =
    p: lib.removePrefix "# " (lib.findFirst (lib.hasPrefix "# ") "# Untitled" (lib.splitString "\n" (builtins.readFile p)));

  # `file` is the basename (clean page URL, e.g. wireguard.html), so chapter basenames must be unique.
  chapters = lib.sort (a: b: a.title < b.title) (
    map (p: {
      inherit p;
      title = chapterTitle p;
      file = baseNameOf p;
    }) (lib.filter (p: lib.hasSuffix ".md" (toString p)) (lib.filesystem.listFilesRecursive (self + "/modules/nixos")))
  );

  # Introduction (prefix) → chapters (auto-sorted) → options reference (suffix). Only the two pins are
  # fixed, so a new co-located chapter appears automatically.
  summary = pkgs.writeText "SUMMARY.md" ''
    # Summary

    [Introduction](introduction.md)

    ${lib.concatMapStringsSep "\n" (c: "- [${c.title}](${c.file})") chapters}

    [Options reference](options.md)
  '';

  bookToml = pkgs.writeText "book.toml" ''
    [book]
    title = "selfhost-nix"
    authors = ["Bruno Henriques"]
    description = "Opinionated NixOS modules for a single-admin selfhost — subsystem concepts and the full selfhost.* options reference."
    language = "en"
    src = "src"

    [output.html]
    site-url = "/selfhost-nix/"
    preferred-dark-theme = "navy"
    git-repository-url = "${repo}"
  '';
in
pkgs.runCommand "selfhost-docs" { nativeBuildInputs = [ pkgs.mdbook ]; } ''
  mkdir -p src
  cp ${./docs/introduction.md} src/introduction.md
  ${lib.concatMapStringsSep "\n" (c: "cp ${c.p} src/${c.file}") chapters}
  { echo "# Options reference"; echo; cat ${optionsDoc.optionsCommonMark}; } > src/options.md
  cp ${summary} src/SUMMARY.md
  cp ${bookToml} book.toml
  mdbook build -d $out
''
