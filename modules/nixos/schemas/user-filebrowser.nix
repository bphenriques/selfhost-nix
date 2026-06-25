{ lib, ... }:
{
  options.services.filebrowser = {
    enable = lib.mkEnableOption "a FileBrowser entry for this user (access is gated by the service auth, not this flag)";
    storage = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.enum [
          "ro"
          "rw"
        ]
      );
      default = { };
      description = "selfhost SMB mounts this user may access, keyed by permission; unioned into their scope (read-write iff any is `rw`).";
    };
    admin = lib.mkEnableOption "FileBrowser admin";
  };
}
