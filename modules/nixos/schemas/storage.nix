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
      description = ''
        Systemd unit names that need the declared mounts.
        If empty, auto-resolved: OCI container units use the backend prefix (e.g. podman-<name>),
        otherwise defaults to the service name.
      '';
    };
  };
}
