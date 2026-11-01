# The transport-neutral ingress facet. Its derived `enable` lives in services-registry.nix.
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
      # Thrown rather than nullOr, so readers need no null branch for a case that cannot occur.
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
