# Shared by the service and task registries: both need to say which shares they read, and both attach
# their automount guards to the entry's `systemdServices`.
{
  lib,
  selfhostCfg,
  ...
}:
{
  options.storage.mounts = lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames selfhostCfg.storage.mounts.smb.shares));
    default = [ ];
    description = "Named selfhost SMB shares this entry may access; their automount guards start before its units.";
  };
}
