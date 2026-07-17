{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "send-notification";
  runtimeInputs = [ pkgs.coreutils ];
  script = ./script.nu;
}
