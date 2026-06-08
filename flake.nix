{
  description = "selfhost-nix: opinionated-but-reusable NixOS modules for declarative selfhost orchestration";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs systems;
      treefmtEval = forAllSystems (
        system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix
      );

      # Single source of truth for the package set; shared by the overlay and the packages output.
      selfhostPackages = pkgs: {
        send-notification = pkgs.callPackage ./packages/send-notification { };
        ntfy-manage = pkgs.callPackage ./packages/ntfy-manage { };
        rustic-manage = pkgs.callPackage ./packages/rustic-manage { };
        pocket-id-manage = pkgs.callPackage ./packages/pocket-id-manage { };
        wg-manage = pkgs.callPackage ./packages/wg-manage { };
      };
    in
    {
      overlays.default = final: _prev: { selfhost = selfhostPackages final; };

      packages = forAllSystems (system: selfhostPackages nixpkgs.legacyPackages.${system});

      # Importing this both loads the framework modules and registers the overlay, so the modules'
      # `pkgs.selfhost.*` references resolve. Consumer must also import sops-nix (the modules use
      # config.sops.{templates,secrets,placeholder}).
      nixosModules.default = {
        imports = [ ./modules/nixos ];
        nixpkgs.overlays = [ self.overlays.default ];
      };

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (
        system:
        {
          formatting = treefmtEval.${system}.config.build.check self;
        }
        // selfhostPackages nixpkgs.legacyPackages.${system}
      );

      devShells = forAllSystems (system: {
        default = import ./shell.nix { pkgs = nixpkgs.legacyPackages.${system}; };
      });
    };
}
