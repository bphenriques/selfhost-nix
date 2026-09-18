_: {
  projectRootFile = "flake.nix";
  programs = {
    # Formatters
    nixfmt.enable = true; # Official Nix formatter.
    nixfmt.width = 120;

    # Checks
    deadnix.enable = true; # Detect unused Nix code
    deadnix.no-lambda-pattern-names = true; # Skip NixOS module args (e.g., { pkgs, lib, ... })
    deadnix.priority = 1; # Run deadnix before statix
    statix.enable = true; # Nix anti-pattern linter
    statix.priority = 2;
  };

  # No nushell formatter. nufmt is pre-1.0 and rewrites valid scripts into ones that do not parse: it
  # strips the parentheses from `data: ((payload $user) | merge {…})` inside a record literal, where
  # nushell then reads the `|` as closure parameters. Gating CI on a formatter that can do that trades a
  # real check for a cosmetic one. `writeNushellApplication` nu-checks every script at build instead,
  # which is what caught this.
}
