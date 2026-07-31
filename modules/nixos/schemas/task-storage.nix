{ lib, selfhostCfg, ... }:
{
  options.storage.smb = lib.mkOption {
    type = lib.types.listOf (lib.types.enum (lib.attrNames selfhostCfg.storage.smb.mounts));
    default = [ ];
    description = "Named selfhost SMB shares this task may access; their automount guards start before the task.";
  };
}
