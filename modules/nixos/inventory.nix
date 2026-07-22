# Use-case-agnostic export of the service registry as normalized facts. Read-only; a consumer
# (dashboard, a public landing page, ...) reads this instead of re-deriving from the submodule.
{ lib, config, ... }:
let
  cfg = config.selfhost;
  accessOf =
    s:
    if s.oidc.enable || s.forwardAuth.enable then
      "sso"
    else if s.access.allowedGroups != [ ] then
      "private"
    else
      "open";
in
{
  options.selfhost.inventory = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    readOnly = true;
    description = ''
      Registered services as use-case-agnostic facts (name, displayName, description, normalized
      access model, ingress, publicUrl, meta.homepage). Read-only; consumers decide presentation.
    '';
    default = lib.mapAttrsToList (_: s: {
      inherit (s) name displayName;
      inherit (s.meta) description homepage category;
      access = accessOf s;
      ingress = s.ingress.enable;
      inherit (s) publicUrl;
    }) cfg.services;
  };
}
