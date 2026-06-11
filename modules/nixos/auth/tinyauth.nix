# tinyauth forward-auth gateway, federated to the selfhost OIDC provider (auth/oidc.nix).
{ config, lib, ... }:
let
  cfg = config.selfhost;
  oidcCfg = cfg.auth.oidc;
  serviceCfg = cfg.services.tinyauth;
in
{
  options.selfhost.auth.forwardAuth.tinyauth = {
    enable = lib.mkEnableOption "tinyauth forward-auth gateway (federates to the selfhost OIDC provider)";
    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "tinyauth listen port (localhost, behind ingress).";
    };
  };

  config = lib.mkIf cfg.auth.forwardAuth.tinyauth.enable {
    selfhost = {
      services.tinyauth = {
        description = "ForwardAuth Gateway";
        port = cfg.auth.forwardAuth.tinyauth.port;
        integrations.homepage.enable = false; # Transparent auth gateway, not a destination.
        access.allowedGroups = with cfg.groups; [
          users
          admin
        ];
        oidc = {
          enable = true;
          callbackURLs = [ "${serviceCfg.publicUrl}/api/oauth/callback/pocketid" ];
          systemd.dependentServices = [ "tinyauth" ];
        };
      };

      runtimeTemplates."tinyauth.env" = {
        content = ''
          TINYAUTH_OAUTH_PROVIDERS_POCKETID_CLIENTID=${cfg.oidcPlaceholder.tinyauth.id}
        '';
        restartUnits = [ "tinyauth.service" ];
      };

      auth.forwardAuth = {
        inherit (serviceCfg) url;
        # tinyauth's Traefik verify endpoint; override forwardAuth.path for a non-Traefik ingress.
        path = lib.mkDefault "/api/auth/traefik";
      };
    };

    services.tinyauth = {
      enable = true;
      environmentFile = cfg.runtimeTemplates."tinyauth.env".path;
      settings = {
        APPURL = serviceCfg.publicUrl;
        SERVER_ADDRESS = serviceCfg.host;
        SERVER_PORT = serviceCfg.port;
        ANALYTICS_ENABLED = false;
        AUTH_SECURECOOKIE = true;
        LOG_LEVEL = "info";

        OAUTH_PROVIDERS_POCKETID_NAME = oidcCfg.provider.displayName;
        OAUTH_PROVIDERS_POCKETID_AUTHURL = "${oidcCfg.provider.issuerUrl}/authorize";
        OAUTH_PROVIDERS_POCKETID_TOKENURL = "${oidcCfg.provider.issuerUrl}/api/oidc/token";
        OAUTH_PROVIDERS_POCKETID_USERINFOURL = "${oidcCfg.provider.issuerUrl}/api/oidc/userinfo";
        OAUTH_PROVIDERS_POCKETID_REDIRECTURL = "${serviceCfg.publicUrl}/api/oauth/callback/pocketid";
        OAUTH_PROVIDERS_POCKETID_SCOPES = "openid profile email groups";
        OAUTH_PROVIDERS_POCKETID_CLIENTSECRETFILE = serviceCfg.oidc.secret.file; # Client ID uses placeholder (no _FILE support); secret uses native file ref
      }
      // lib.listToAttrs (
        lib.mapAttrsToList (_: svc: {
          name = "APPS_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] svc.subdomain)}_OAUTH_GROUPS";
          value = lib.concatStringsSep "," svc.access.allowedGroups;
        }) (lib.filterAttrs (_: s: s.forwardAuth.enable) cfg.services)
      );
    };

    systemd.services.tinyauth.serviceConfig.SupplementaryGroups =
      serviceCfg.oidc.systemd.supplementaryGroups;
  };
}
