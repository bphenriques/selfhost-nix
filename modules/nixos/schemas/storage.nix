# Shared by the service and task registries: both need to say which shares they read, and both attach
# their automount guards to the entry's `systemdServices`.
{
  lib,
  selfhostCfg,
  ...
}:
{
  options.storage = {
    mounts = lib.mkOption {
      type = lib.types.listOf (lib.types.enum (lib.attrNames selfhostCfg.storage.mounts.smb.shares));
      default = [ ];
      description = "Named selfhost SMB shares this entry may access; their automount guards start before its units.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      example = [
        "romm"
        "nginx"
      ];
      description = "POSIX users this entry's units run as. Each joins the group of every `mounts` share that grants by group, so adding a share is one edit rather than two. Empty grants nothing, which is right for a unit running as root or under DynamicUser. A share owned by a uid is skipped, so a second consumer of one still needs its group granted by hand.";
    };
  };
}
