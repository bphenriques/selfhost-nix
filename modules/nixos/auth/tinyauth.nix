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
  };

  config = lib.mkIf cfg.auth.forwardAuth.tinyauth.enable {
    selfhost = {
      services.tinyauth = {
        displayName = lib.mkDefault "Tinyauth";
        meta.homepage = lib.mkDefault "https://tinyauth.app";
        meta.description = lib.mkDefault "ForwardAuth Gateway";
        meta.category = lib.mkDefault "identity";
        port = lib.mkDefault 3000;
        integrations.homepage.enable = false; # Transparent auth gateway, not a destination.
        # Who may pass the gateway at all: overridable, since narrowing it is the consumer's call.
        access.allowedGroups = lib.mkDefault (
          with cfg.groups;
          [
            users
            admin
          ]
        );
        access.model = "oidc";
        access.oidc = {
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
        OAUTH_PROVIDERS_POCKETID_CLIENTSECRETFILE = serviceCfg.access.oidc.secret.file; # Client ID uses placeholder (no _FILE support); secret uses native file ref
      }
      // lib.listToAttrs (
        lib.mapAttrsToList (_: svc: {
          name = "APPS_${lib.toUpper (lib.replaceStrings [ "-" ] [ "_" ] svc.subdomain)}_OAUTH_GROUPS";
          value = lib.concatStringsSep "," svc.access.allowedGroups;
          # Empty allowedGroups means unrestricted, which is the absent key — emitting "" would ask
          # tinyauth to match a group nobody has.
        }) (lib.filterAttrs (_: s: s.access.model == "forwardAuth" && s.access.allowedGroups != [ ]) cfg.services)
      );
    };

    systemd.services.tinyauth.serviceConfig.SupplementaryGroups = serviceCfg.access.oidc.systemd.supplementaryGroups;
  };
}
