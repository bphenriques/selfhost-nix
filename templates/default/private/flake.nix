{
  description = "Private build-time data for my selfhost fleet";

  # Confidential but not secret-at-rest (domain, emails, per-user identity) lives in plain Nix here;
  # secret-at-rest values live in hosts/<name>/secrets.yaml, encrypted with sops.
  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
    in
    {
      hosts = lib.genAttrs (builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir ./hosts))) (
        name: import (./hosts + "/${name}")
      );
    };
}
