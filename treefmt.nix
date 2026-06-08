{ pkgs, lib, ... }:
{
  projectRootFile = "flake.nix";
  programs = {
    # Formatters
    nixfmt.enable = true; # Official Nix formatter.
    shfmt.enable = true; # Shell script formatter
    mdformat.enable = true; # Markdown formatter
    mdformat.plugins = ps: [ ps.mdformat-gfm ]; # GitHub Flavored Markdown (tables, task lists, strikethrough)
    mdformat.settings.number = true; # Preserve consecutive numbering in ordered lists

    # Checks
    shellcheck.enable = true; # Shell script linter
    shellcheck.severity = "warning"; # Ignore info-level hints (e.g., SC1091)
    deadnix.enable = true; # Detect unused Nix code
    deadnix.no-lambda-pattern-names = true; # Skip NixOS module args (e.g., { pkgs, lib, ... })
    deadnix.priority = 1; # Run deadnix before statix
    statix.enable = true; # Nix anti-pattern linter
    statix.priority = 2;
  };

  # Follow Google's Shell Style Guide: https://google.github.io/styleguide/shellguide.html
  settings.formatter.shfmt.options = [
    "-i"
    "2"
    "-ci"
    "-bn"
    "-s"
  ];

  # Nushell formatter (not yet in treefmt-nix).
  settings.formatter.nufmt =
    let
      config = pkgs.writeText "nufmt.nuon" "{ indent: 2, line_length: 120 }";
    in
    {
      command = lib.getExe pkgs.nufmt;
      options = [
        "--config"
        (toString config)
      ];
      includes = [ "*.nu" ];
    };
}
