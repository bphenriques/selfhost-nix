{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "homelab-secrets-bin";
  runtimeInputs = [ pkgs.coreutils ];
  script = ./script.nu;
}
