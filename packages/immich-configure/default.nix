{ lib, pkgs, ... }:
(import ../../modules/nixos/builders.nix { inherit pkgs lib; }).writeNushellApplication {
  name = "immich-configure";
  script = ./configure.nu;
}
