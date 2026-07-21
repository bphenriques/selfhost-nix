{ name, lib, ... }:
{
  options.integrations.homepage = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "homepage entry for this service";

        group = lib.mkOption {
          type = lib.types.str;
          default = "Services";
          description = "Free-form tile group this service belongs to; you map groups to tabs/layout in your dashboard.";
        };

        icon = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "${name}.svg";
          description = "Icon name from dashboard-icons (e.g. 'miniflux.svg')";
        };

        settings = lib.mkOption {
          type = lib.types.attrs;
          default = { };
          description = "Extra homepage tile settings merged into the generated entry (e.g. a `widget`).";
        };
      };
    };
    default = { };
    description = "Homepage dashboard integration";
  };
}
