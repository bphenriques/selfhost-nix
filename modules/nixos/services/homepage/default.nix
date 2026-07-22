# First-party homepage app: renders the framework's generated tiles (selfhost.dashboards.generatedTiles)
# with gethomepage. Visual presentation — theme, layout, widgets, branding — is the consumer's: set it on
# services.homepage-dashboard directly.
{ lib, config, ... }:
let
  app = config.selfhost.apps.homepage;
  serviceCfg = config.selfhost.services.homepage;
in
{
  options.selfhost.apps.homepage = {
    enable = lib.mkEnableOption "the first-party homepage dashboard app (gethomepage)";
    port = lib.mkOption {
      type = lib.types.port;
      default = 3001;
      description = "homepage listen port (localhost, behind ingress).";
    };
  };

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost.services.homepage = {
      meta.description = "Dashboard";
      inherit (app) port;
      integrations.homepage.enable = false; # the dashboard doesn't list itself
    };

    services.homepage-dashboard = {
      enable = true;
      listenPort = app.port;
      allowedHosts = serviceCfg.publicHost;
      services = lib.mapAttrsToList (group: tiles: { ${group} = tiles; }) config.selfhost.dashboards.generatedTiles;
    };
  };
}
