{ ... }:
{
  imports = [
    ./hardware-configuration.nix # generated; see the file
    ./selfhost.nix # what to run
    ./secrets.nix # where secrets come from (the only backend-specific file)
  ];

  networking.hostName = "myhost";

  # Match the NixOS version you installed with. Do not bump casually.
  system.stateVersion = "24.11";
}
