# Gitea's per-user surface, kept beside the app rather than in core's user schema.
{ lib, ... }:
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options.apps.gitea = {
            enable = lib.mkEnableOption "a Gitea account for this user";
            admin = lib.mkOption {
              type = lib.types.bool;
              default = config.isAdmin;
              description = "Gitea site-admin (reconciled each run); defaults to the user's fleet isAdmin.";
            };
          };
        }
      )
    );
  };
}
