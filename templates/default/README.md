# My selfhost fleet

A starting point for a [selfhost-nix](https://github.com/bphenriques/selfhost-nix) deployment: a plain
NixOS flake (no flake-parts, no abstractions) with one host and a nested `private/` flake for confidential
data.

## Layout

```
flake.nix                 # one nixosConfiguration, wired inline
hosts/myhost/
  default.nix             # imports the three below + stateVersion
  hardware-configuration.nix   # placeholder — generate this
  selfhost.nix            # what to run (pure selfhost.* config)
  secrets.nix             # where secrets come from (the only sops-specific file)
private/                  # confidential, build-time data — split into its own repo
  hosts/myhost/{settings.nix, users/, secrets.yaml}
```

## Set it up

1. **Hardware**: `nixos-generate-config --show-hardware-config > hosts/myhost/hardware-configuration.nix`.
2. **Identity**: edit `private/hosts/myhost/settings.nix` (domain, SMTP) and `private/hosts/myhost/users/admin.nix`.
3. **Secrets**: set your key in `private/.sops.yaml`, fill `private/hosts/myhost/secrets.yaml`, then
   `sops --encrypt --in-place private/hosts/myhost/secrets.yaml`.
4. **Build**: `nixos-rebuild switch --flake .#myhost`.

## Make `private/` actually private

`private/` is a nested flake purely so the template is self-contained. To keep it out of your public repo:

1. Move `private/` into its own private git repo.
2. In `flake.nix`, change the input to `private.url = "git+ssh://git@github.com/<you>/<repo>";`.
3. `nix flake update private`.

Nothing else changes — `flake.nix` already reads it as `private.hosts.myhost`.

## Extend from here

- **More apps**: `selfhost.apps.<name>.enable = true;` in `selfhost.nix`; opt users in via
  `apps.<name>` in their private user file.
- **More users**: add `private/hosts/myhost/users/<name>.nix` and reference it in `settings.nix`.
- **More hosts**: add `private/hosts/<host>/` and another `nixosConfigurations.<host>` block.
- **Beyond the basics** — monitoring, backups, storage mounts, and consumer-owned per-user config via
  `selfhost.users.<name>.extraConfig` — see the selfhost-nix docs.
