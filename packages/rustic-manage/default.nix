{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "rustic-manage-bin";
  runtimeInputs = [ pkgs.rustic ];
  script = ./script.nu;
}
