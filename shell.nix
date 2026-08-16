{ pkgs }:
pkgs.mkShellNoCC {
  name = "selfhost-nix";
  meta.description = "Development shell for selfhost-nix";

  packages = [
    pkgs.git
    pkgs.mdbook # `mdbook serve docs`, per the docs chapter
    pkgs.nushell # the reconcilers under modules/nixos/services/*/ are .nu scripts
  ];
}
