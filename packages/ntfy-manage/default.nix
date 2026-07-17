{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "ntfy-manage";
  runtimeInputs = with pkgs; [
    coreutils
    ntfy-sh
  ];
  script = ./script.nu;
}
