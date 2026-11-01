# Traefik's middleware escape hatch, the only vendor-specific part of the service schema.
{ lib, ... }:
{
  options.traefik.middlewares = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.unspecified);
    default = { };
    description = "Extra Traefik middleware definitions to attach to this service's router";
  };
}
