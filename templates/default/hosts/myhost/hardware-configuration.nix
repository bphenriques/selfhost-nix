# Placeholder. Replace with your machine's real hardware config:
#   nixos-generate-config --show-hardware-config > hosts/myhost/hardware-configuration.nix
# Until you do, the host won't build (no filesystems/bootloader) — that's expected.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  # boot.loader.systemd-boot.enable = true;
  # fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
  # swapDevices = [ ];
}
