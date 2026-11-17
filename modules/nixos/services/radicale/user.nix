# Radicale's per-user surface, kept beside the app rather than in core's user schema.
{ lib, ... }:
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.services.radicale = {
          enable = lib.mkEnableOption "Radicale CalDAV/CardDAV access for this user";

          access.serviceAccounts = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Service accounts that may read, add and change this user's items and collections, but never delete, replace, rename or share a collection.";
          };
        };
      }
    );
  };
}
