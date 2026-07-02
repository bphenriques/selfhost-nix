# Radicale's per-user surface, kept beside the app rather than in core's user schema.
{ lib, ... }:
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.apps.radicale.enable = lib.mkEnableOption "Radicale CalDAV/CardDAV access for this user";
      }
    );
  };
}
