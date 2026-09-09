# The ingress facet of a service entry: whether it is published, and at what public address. Everything
# here is transport-neutral, so any ingress implementation can consume it. Vendor-specific additions go
# in a sibling file (traefik.nix) and should stay minimal — the neutral surface is the contract.
#
# The derived default for `ingress.enable` is not here: it lives with the registry's other composition
# defaults in services-registry.nix, where they read as one block.
{
  name,
  config,
  lib,
  selfhostCfg,
  ...
}:
{
  options = {
    ingress.enable = lib.mkEnableOption "HTTP ingress route for this service" // {
      defaultText = lib.literalMD "on once the entry has a backend to route to and its `access.model` is satisfied";
    };

    subdomain = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Subdomain prefix (combined with domain for publicHost)";
    };

    publicHost = lib.mkOption {
      type = lib.types.str;
      # Thrown rather than nullOr: keeping the type `str` spares every reader a null branch for a
      # case that cannot happen on a host that routes anything.
      default =
        if selfhostCfg.ingress.domain == null then
          throw "selfhost.services.${name}.publicHost needs selfhost.ingress.domain, which is unset."
        else
          "${config.subdomain}.${selfhostCfg.ingress.domain}";
      defaultText = lib.literalMD "`<subdomain>.<ingress.domain>`";
      description = "Public hostname (derived from subdomain and ingress.domain)";
    };

    publicUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${config.publicHost}";
      defaultText = lib.literalMD "`https://<publicHost>`";
      description = "Full public URL (derived from publicHost)";
    };
  };
}
