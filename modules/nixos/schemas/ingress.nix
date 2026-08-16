# Ingress-level service-schema contributions: the Traefik-specific middleware escape hatch. Kept out of
# the transport-neutral base module so the registry stays a contract any ingress implementation could
# consume. The gate itself is `access.model`, which is transport-neutral and lives in the base module.
{ lib, ... }:
{
  options = {
    traefik.middlewares = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.unspecified);
      default = { };
      description = "Extra Traefik middleware definitions to attach to this service's router";
    };
  };
}
