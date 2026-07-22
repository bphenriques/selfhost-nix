{ name, lib, ... }:
{
  options = {
    name = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Registry identifier (defaults to attribute name)";
    };

    displayName = lib.mkOption {
      type = lib.types.str;
      default = name;
      description = "Human-readable name (defaults to attribute name)";
    };

    # Consumer-agnostic descriptive metadata, mirroring nixpkgs `meta` (name/displayName stay flat,
    # like nixpkgs pname). `category` is selfhost's own grouping key.
    meta = {
      description = lib.mkOption {
        type = lib.types.str;
        description = "Short description (nixpkgs `meta.description`).";
      };

      homepage = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Upstream project homepage (nixpkgs `meta.homepage`).";
      };

      category = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Canonical grouping key; a consumer surface (e.g. a landing page) groups services by this.";
      };
    };
  };
}
