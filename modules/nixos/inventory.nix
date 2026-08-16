# Use-case-agnostic export of the service registry as normalized facts. Read-only; a consumer
# (dashboard, a public landing page, ...) reads this instead of re-deriving from the submodule.
{ lib, config, ... }:
let
  cfg = config.selfhost;
  accessOf = s: if s.access.model == "oidc" || s.access.model == "forwardAuth" then "sso" else s.access.model;
in
{
  options.selfhost.inventory = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    readOnly = true;
    description = ''
      Registered services as use-case-agnostic facts (name, displayName, description, normalized
      access model, ingress, publicUrl, meta.homepage). Read-only; consumers decide presentation.

      `publicUrl` is present only when `ingress` is true: it derives from `ingress.domain`, which a
      host that routes nothing may leave unset.
    '';
    defaultText = lib.literalMD "derived from `selfhost.services`";
    default = lib.mapAttrsToList (
      _: s:
      {
        inherit (s) name displayName;
        inherit (s.meta) description homepage category;
        access = accessOf s;
        ingress = s.ingress.enable;
      }
      // lib.optionalAttrs s.ingress.enable { inherit (s) publicUrl; }
    ) cfg.services;
  };
}
