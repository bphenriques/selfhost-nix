{ options, lib, ... }:
{
  options.selfhost.auth.forwardAuth = {
    active = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = options.selfhost.auth.forwardAuth.url.isDefined;
      defaultText = lib.literalMD "true once a provider defines `url`";
      description = "Whether a forward-auth provider is active. Compose service defaults against this.";
    };
    url = lib.mkOption {
      type = lib.types.str;
      description = "Base URL of the forward-auth endpoint, set by the active provider and consumed by the ingress provider. Left undefined until one is, which is what `active` reads.";
    };
    path = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Verify path appended to `url` for the ingress forward-auth middleware (e.g. /api/auth/traefik); set by the active provider.";
    };
  };
}
