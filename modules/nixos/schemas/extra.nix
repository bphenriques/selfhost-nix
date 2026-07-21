{ lib, ... }:
{
  options.extraConfig = lib.mkOption {
    type = lib.types.submodule { freeformType = lib.types.attrsOf lib.types.anything; };
    default = { };
    description = "Consumer-owned per-service data with no first-class option (e.g. a landing-page tag); selfhost-nix never reads it. Co-located on the service entry instead of a parallel tree keyed by name. Read back at `config.selfhost.services.<name>.extraConfig`.";
  };
}
