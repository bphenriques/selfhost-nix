{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "pocket-id-manage-bin";
  runtimeInputs = [ pkgs.coreutils ];
  script = ./script.nu;
}
