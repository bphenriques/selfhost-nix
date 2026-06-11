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

    description = lib.mkOption {
      type = lib.types.str;
      description = "Short description";
    };
  };
}
