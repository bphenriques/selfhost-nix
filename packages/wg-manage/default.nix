{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "wg-manage-bin";
  runtimeInputs = with pkgs; [
    wireguard-tools
    qrencode
    coreutils
  ];
  script = ./script.nu;
}
