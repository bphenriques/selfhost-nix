# Generates dashboard tiles from the registry, and (when enabled) runs homepage-dashboard with
# optional custom background/favicon.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  hp = cfg.dashboards.homepage;
  serviceCfg = cfg.services.homepage;

  homepageServices = lib.filter (s: s.integrations.homepage.enable) (lib.attrValues cfg.services);

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

  homepageExternals = lib.filter (e: e.integrations.homepage.enable) (lib.attrValues cfg.external);

  mkExternalEntry = entry: {
    "${entry.displayName}" = {
      inherit (entry) description;
      href = entry.url;
    }
    // lib.optionalAttrs (entry.integrations.homepage.icon != null) {
      inherit (entry.integrations.homepage) icon;
    };
  };

  servicesByTab = builtins.groupBy (s: s.integrations.homepage.tab) homepageServices;
  externalsByTab = builtins.groupBy (e: e.integrations.homepage.tab) homepageExternals;

  mkTabServices =
    tab:
    let
      svcs = servicesByTab.${tab} or [ ];
      exts = externalsByTab.${tab} or [ ];
    in
    map mkServiceEntry svcs ++ map mkExternalEntry exts;

  # Custom assets to symlink into homepage's public image dir (only the ones that are set).
  assets = lib.filter (a: a.source != null) [
    {
      name = "background.png";
      source = hp.background;
    }
    {
      name = "favicon.svg";
      source = hp.favicon;
    }
  ];

  package =
    if assets == [ ] then
      pkgs.homepage-dashboard
    else
      pkgs.homepage-dashboard.overrideAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          mkdir -p $out/share/homepage/public/images
          ${lib.concatMapStringsSep "\n" (
            a: "ln -s ${a.source} $out/share/homepage/public/images/${a.name}"
          ) assets}
        '';
      });
in
{
  options.selfhost.dashboards = {
    generatedHomeServices = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = mkTabServices "Home";
      readOnly = true;
      description = "Auto-generated Home tab tiles (read-only); read this from your own dashboard if you disable the bundled provider.";
    };

    generatedAdminServices = lib.mkOption {
      type = lib.types.listOf lib.types.anything;
      default = mkTabServices "Admin";
      readOnly = true;
      description = "Auto-generated Admin tab tiles (read-only).";
    };

    homepage = {
      enable = lib.mkEnableOption "bundled homepage dashboard (gethomepage)";

      port = lib.mkOption {
        type = lib.types.port;
        default = 3001;
        description = "homepage listen port (localhost, behind ingress).";
      };

      background = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Background image file, symlinked into the dashboard's assets.";
      };

      favicon = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Favicon file, symlinked into the dashboard's assets.";
      };

      settings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = "homepage settings, merged over the bundled defaults.";
      };

      widgets = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "homepage info widgets (resources, weather, …).";
      };

      extraServices = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        default = [ ];
        description = "Extra service groups appended after the generated Home tiles.";
      };

      environmentFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Environment files for HOMEPAGE_VAR_* substitutions (e.g. widget API keys).";
      };
    };
  };

  config = lib.mkIf hp.enable {
    selfhost.services.homepage = {
      description = "Dashboard";
      inherit (hp) port;
    };

    services.homepage-dashboard = {
      enable = true;
      inherit package;
      listenPort = hp.port;
      allowedHosts = serviceCfg.publicHost;
      inherit (hp) widgets environmentFiles;

      services =
        lib.optional (cfg.dashboards.generatedHomeServices != [ ]) {
          "Services" = cfg.dashboards.generatedHomeServices;
        }
        ++ hp.extraServices
        ++ lib.optional (cfg.dashboards.generatedAdminServices != [ ]) {
          "Admin" = cfg.dashboards.generatedAdminServices;
        };

      settings = {
        title = "Home";
        theme = "dark";
        headerStyle = "clean";
        statusStyle = "dot";
        hideVersion = true;
        target = "_blank";
      }
      // lib.optionalAttrs (hp.background != null) { background = "/images/background.png"; }
      // lib.optionalAttrs (hp.favicon != null) { favicon = "/images/favicon.svg"; }
      // hp.settings;
    };
  };
}
