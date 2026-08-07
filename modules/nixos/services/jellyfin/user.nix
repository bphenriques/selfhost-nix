# Jellyfin's per-user surface, kept beside the app rather than in core's user schema.
{ lib, ... }:
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.services.jellyfin = {
          enable = lib.mkEnableOption "a Jellyfin account for this user";

          passwordFile = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Path to a file holding the initial password, applied at account creation and never reconciled. Null generates a random one.";
          };

          policy = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            example = {
              IsHidden = false;
              EnableSubtitleManagement = true;
            };
            description = "Fields merged into this account's Jellyfin UserPolicy on every run, applied verbatim. Anything not named here keeps whatever Jellyfin holds.";
          };
        };
      }
    );
  };
}
