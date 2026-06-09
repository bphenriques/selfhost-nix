{
  name,
  lib,
  selfhostCfg,
  ...
}:
{
  options.storage = {
    smb = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames selfhostCfg.storage.smb.mounts));
      default = [ ];
      description = "Named selfhost SMB mounts this service requires.";
    };

    systemdServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Units needing the declared mounts; if empty, auto-resolved from the service or OCI-container name.";
    };
  };
}
