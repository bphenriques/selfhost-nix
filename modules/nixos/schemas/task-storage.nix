{ lib, selfhostCfg, ... }:
{
  options.storage.mounts = lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames selfhostCfg.storage.mounts.smb.shares));
    default = [ ];
    description = "Named selfhost SMB shares this task may access; their automount guards start before the task.";
  };
}
