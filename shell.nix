{ pkgs }:
pkgs.mkShellNoCC {
  name = "selfhost-nix";
  meta.description = "Development shell for selfhost-nix";

  packages = [
    pkgs.git
  ];
}
