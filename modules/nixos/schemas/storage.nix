{
  name,
  lib,
  selfhostCfg,
  ...
}:
{
  options.storage = {
    mounts = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames selfhostCfg.storage.mounts.smb.shares));
      default = [ ];
      description = "Named selfhost SMB shares this service may access; their automount guards start before the service.";
    };

    systemdServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Systemd service names to guard instead of the inferred service or OCI-container name.";
    };
  };
}
