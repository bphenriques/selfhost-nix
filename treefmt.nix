{ pkgs, lib, ... }:
{
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
