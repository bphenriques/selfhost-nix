{ config, lib, ... }:
{
  options.selfhost.auth.forwardAuth = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = config.selfhost.auth.forwardAuth.url != null;
      defaultText = lib.literalMD "true once a provider sets `url`";
      description = "Whether a forward-auth provider is active. Compose service defaults against this.";
    };
    url = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Base URL of the forward-auth endpoint, set by the active provider and consumed by the ingress provider (null = no provider active).";
    };
    path = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Verify path appended to `url` for the ingress forward-auth middleware (e.g. /api/auth/traefik); set by the active provider.";
    };
  };
}
