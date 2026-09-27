```bash
nix fmt                                        # format + lint (treefmt)
nix flake check -L                             # run everything: formatting, package builds, and all VM tests
nix build -L .#checks.x86_64-linux.vm-ingress  # run a single VM test
nix build .#docs                               # docs site → result/index.html
```

VM tests ([`nixosTest`](https://nixos.org/manual/nixos/stable/#sec-nixos-tests), one concern per file under [`tests/`](tests/), Linux + KVM) are exposed as flake checks, so `nix flake check` runs them all in one go. Conventions and how to extend live in [`AGENTS.md`](AGENTS.md).
