# Data tier: derive dashboard tiles from services/externals that opt into integrations.homepage. Read-only;
# the bundled renderer (selfhost.apps.homepage) consumes it, or read it into a dashboard you own.
{ lib, config, ... }:
let
  cfg = config.selfhost;

  homepageServices = lib.filter (s: s.integrations.homepage.enable) (lib.attrValues cfg.services);
  homepageExternals = lib.filter (e: e.integrations.homepage.enable) (lib.attrValues cfg.external);

  mkServiceEntry = service: {
    "${service.displayName}" = {
      inherit (service.meta) description;
    }
    // lib.optionalAttrs service.ingress.enable {
      href = service.publicUrl;
      siteMonitor = "${service.publicUrl}${service.healthcheck.path}";
    }
    // lib.optionalAttrs (service.integrations.homepage.icon != null) {
      inherit (service.integrations.homepage) icon;
    }
    // service.integrations.homepage.settings;
  };

  mkExternalEntry = entry: {
    "${entry.displayName}" = {
      inherit (entry.meta) description;
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
    group: map mkServiceEntry (servicesByGroup.${group} or [ ]) ++ map mkExternalEntry (externalsByGroup.${group} or [ ])
  );
in
{
  options.selfhost.dashboards.generatedTiles = lib.mkOption {
    type = lib.types.attrsOf (lib.types.listOf lib.types.anything);
    default = tilesByGroup;
    readOnly = true;
    description = "Service/external tiles keyed by `integrations.homepage.group` (read-only). The bundled `apps.homepage` renders these; otherwise read them into a dashboard you own and decide tabs/layout.";
  };
}
