{
  description = "My selfhost fleet (built on selfhost-nix)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    # The framework. Pin to a tag/rev for reproducibility; point at your fork if you have one.
    selfhost-nix.url = "github:bphenriques/selfhost-nix";
    selfhost-nix.inputs.nixpkgs.follows = "nixpkgs";

    # The secrets backend used by hosts/<name>/secrets.nix. Swap for agenix/plain files there if you prefer.
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Confidential, build-time data (domain, users, encrypted secrets). Starts as a nested flake so the
    # template is self-contained; lift ./private into its own private repo and change this to git+ssh://…
    private.url = "path:./private";
    private.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      selfhost-nix,
      sops-nix,
      private,
      ...
    }:
    {
      # One host, wired inline — no helper, no flake-parts. Add more hosts by repeating the block.
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = {
          private = private.hosts.myhost;
        };
        modules = [
          selfhost-nix.nixosModules.default
          sops-nix.nixosModules.sops
          ./hosts/myhost
        ];
      };
    };
}
