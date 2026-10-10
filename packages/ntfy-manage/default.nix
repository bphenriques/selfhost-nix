{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "ntfy-manage-bin";
  runtimeInputs = with pkgs; [
    coreutils
    ntfy-sh
  ];
  script = ./script.nu;
}
