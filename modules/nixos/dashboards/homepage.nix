# Builds read-only `dashboards.generatedTiles` from the registry; the bundle renders them, or a
# consumer reads them into their own dashboard (README "Dashboard tiles").
{ lib, config, ... }:
let
  cfg = config.selfhost;
  hp = cfg.dashboards.homepage;
  serviceCfg = cfg.services.homepage;

  homepageServices = lib.filter (s: s.integrations.homepage.enable) (lib.attrValues cfg.services);
  homepageExternals = lib.filter (e: e.integrations.homepage.enable) (lib.attrValues cfg.external);

  mkServiceEntry = service: {
    "${service.displayName}" = {
      inherit (service) description;
    }
    // lib.optionalAttrs service.ingress.enable {
      href = service.publicUrl;
      siteMonitor = "${service.publicUrl}${service.healthcheck.path}";
    }
    // lib.optionalAttrs (service.integrations.homepage.icon != null) {
      inherit (service.integrations.homepage) icon;
    }
    // service.integrations.homepage.extraConfig;
  };

  mkExternalEntry = entry: {
    "${entry.displayName}" = {
      inherit (entry) description;
      href = entry.url;
    }
    // lib.optionalAttrs (entry.integrations.homepage.icon != null) {
      inherit (entry.integrations.homepage) icon;
    };
  };

  groupOf = x: x.integrations.homepage.group;
  servicesByGroup = builtins.groupBy groupOf homepageServices;
  externalsByGroup = builtins.groupBy groupOf homepageExternals;
  allGroups = lib.unique (map groupOf (homepageServices ++ homepageExternals));

  tilesByGroup = lib.genAttrs allGroups (
    group:
    map mkServiceEntry (servicesByGroup.${group} or [ ])
    ++ map mkExternalEntry (externalsByGroup.${group} or [ ])
  );
in
{
  options.selfhost.dashboards = {
    generatedTiles = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.anything);
      default = tilesByGroup;
      readOnly = true;
      description = "Service/external tiles keyed by `integrations.homepage.group` (read-only). The bundled provider renders these; on the data tier you read them into your own dashboard and decide tabs/layout.";
    };

    homepage = {
      enable = lib.mkEnableOption "bundled homepage dashboard (gethomepage); disable to read generatedTiles into your own";

      port = lib.mkOption {
        type = lib.types.port;
        default = 3001;
        description = "homepage listen port (localhost, behind ingress).";
      };
    };
  };

  config = lib.mkIf hp.enable {
    selfhost.services.homepage = {
      description = "Dashboard";
      inherit (hp) port;
      integrations.homepage.enable = false; # The dashboard doesn't list itself.
    };

    services.homepage-dashboard = {
      enable = true;
      listenPort = hp.port;
      allowedHosts = serviceCfg.publicHost;
      services = lib.mapAttrsToList (group: tiles: { ${group} = tiles; }) cfg.dashboards.generatedTiles;
    };
  };
}
