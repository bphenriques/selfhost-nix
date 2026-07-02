# Miniflux's per-user surface, kept beside the app rather than in core's user schema.
{ lib, ... }:
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        # Freeform passthrough to Miniflux's stable, idempotent partial-update PUT; don't copy to apps
        # without those properties.
        options.apps.miniflux.settings = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          example = {
            theme = "dark_serif";
            display_mode = "fullscreen";
          };
          description = "Per-user Miniflux preferences, applied verbatim via the user-update API (is_admin is framework-managed and ignored here).";
        };
      }
    );
  };
}
