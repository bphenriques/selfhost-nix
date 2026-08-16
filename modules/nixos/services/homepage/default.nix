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
  };

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost.services.homepage = {
      displayName = lib.mkDefault "Homepage";
      meta.description = lib.mkDefault "Dashboard";
      port = lib.mkDefault 3001;
      access.model = "open"; # a link list, gated by whatever gates the links
      integrations.homepage.enable = false; # the dashboard doesn't list itself
    };

    services.homepage-dashboard = {
      enable = true;
      listenPort = serviceCfg.port;
      allowedHosts = serviceCfg.publicHost;
      services = lib.mapAttrsToList (group: tiles: { ${group} = tiles; }) config.selfhost.dashboards.generatedTiles;
    };
  };
}
