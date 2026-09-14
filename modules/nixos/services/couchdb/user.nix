# CouchDB's per-user surface, kept beside the app rather than in core's user schema.
{ lib, ... }:
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.services.couchdb = {
          enable = lib.mkEnableOption "a CouchDB account for this user";
          databases = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
            description = "Databases created for this user, with the user as their sole admin and member.";
          };
        };
      }
    );
  };
}
