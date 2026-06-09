# Neutral forward-auth contract: the endpoint a provider (e.g. tinyauth) supplies and the ingress
# consumes. Per-service opt-in is `services.<name>.forwardAuth.enable` (schemas/ingress.nix).
{ lib, ... }:
{
  options.selfhost.auth.forwardAuth = {
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
