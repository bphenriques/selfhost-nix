# The only vendor-specific part of the service schema: Traefik's middleware escape hatch. Kept out of
# the neutral ingress facet (./default.nix) so the registry stays a contract any implementation could
# consume. A second implementation adds its own sibling rather than growing this one.
{ lib, ... }:
{
  options.traefik.middlewares = lib.mkOption {
    type = lib.types.attrsOf (lib.types.attrsOf lib.types.unspecified);
    default = { };
    description = "Extra Traefik middleware definitions to attach to this service's router";
  };
}
