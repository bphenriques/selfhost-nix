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
      treefmtEval = forAllSystems (system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix);

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

      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        selfhostPackages pkgs
        // {
          docs = import ./docs.nix { inherit pkgs self; };
        }
      );

      # Loads the framework modules and registers the overlay so `pkgs.selfhost.*` resolves.
      # Secrets are path-based: modules read only file paths, so the consumer wires them from
      # any backend (sops-nix, agenix, plain files).
      nixosModules.default = {
        imports = [ ./modules/nixos ];
        nixpkgs.overlays = [ self.overlays.default ];
      };

      # Standalone access module (no selfhost framework); the selfhost adapter lives in nixosModules.default.
      nixosModules.filebrowser-multiuser = ./modules/nixos/filebrowser;

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          formatting = treefmtEval.${system}.config.build.check self;
        }
        // selfhostPackages pkgs
        # VM integration tests (nixosTest); Linux-only.
        // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux (import ./tests { inherit pkgs self; })
      );

      devShells = forAllSystems (system: {
        default = import ./shell.nix { pkgs = nixpkgs.legacyPackages.${system}; };
      });
    };
}
