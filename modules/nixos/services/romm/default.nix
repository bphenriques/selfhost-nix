# First-party RomM app: a ROM library manager with a built-in emulator. Upstream serves the frontend,
# the ROM downloads and the emulator's cross-origin headers from its own nginx virtual host, so ingress
# routes to that vhost and the API keeps a separate socket behind it.
{
  config,
  lib,
  ...
}:
let
  cfg = config.selfhost;
  app = cfg.apps.romm;
  serviceCfg = cfg.services.romm;
  oidcCfg = cfg.auth.oidc;
  rommCfg = config.services.romm;

  federated = serviceCfg.access.model == "oidc";
  publicIsTls = lib.hasPrefix "https://" serviceCfg.publicUrl;

  units = [
    "romm"
    "romm-worker"
    "romm-scheduler"
  ]
  ++ lib.optional rommCfg.watcher.enable "romm-watcher";
in
{
  options.selfhost.apps.romm.enable = lib.mkEnableOption "the first-party RomM app (ROM library manager)";

  config = lib.mkIf (cfg.enable && app.enable) {
    selfhost = {
      services.romm = {
        displayName = lib.mkDefault "RomM";
        meta.homepage = lib.mkDefault "https://romm.app";
        meta.description = lib.mkDefault "ROM Manager";
        meta.category = lib.mkDefault "media";
        port = lib.mkDefault 8095;
        healthcheck.path = "/api/heartbeat";
        # The worker, the scheduler and the watcher read the same library, so the automount guards and
        # the failure notifications have to cover them too.
        systemdServices = units;
        # RomM keeps its local accounts either way, so it federates only where a provider exists.
        access.model = lib.mkDefault (if oidcCfg.active then "oidc" else "native");
        access.oidc = {
          callbackURLs = lib.mkDefault [ "${serviceCfg.publicUrl}/api/oauth/openid" ];
          systemd.dependentServices = [ "romm" ];
        };
      };

      internal.listeningPorts = [
        {
          name = "romm/api";
          host = rommCfg.listenAddress;
          inherit (rommCfg) port;
        }
      ];

      # RomM reads the client credentials from the environment: the `_FILE` convention its container
      # documents comes from that image's entrypoint, which the package does not ship.
      runtimeTemplates."romm.env" = lib.mkIf federated {
        content = ''
          OIDC_CLIENT_ID=${cfg.oidcPlaceholder.romm.id}
          OIDC_CLIENT_SECRET=${cfg.oidcPlaceholder.romm.secret}
        '';
        restartUnits = [ "romm.service" ];
      };
    };

    services.romm = {
      enable = true;
      nginx.virtualHost = lib.mkDefault serviceCfg.publicHost;
      extraEnvironment = {
        # The vhost is plain HTTP behind the gateway, so upstream would derive both of these wrong from it.
        ROMM_BASE_URL = lib.mkDefault serviceCfg.publicUrl;
        ROMM_SESSION_SECURE_COOKIE = lib.mkDefault (lib.boolToString publicIsTls);
      }
      // lib.optionalAttrs federated {
        OIDC_ENABLED = "true";
        OIDC_PROVIDER = oidcCfg.provider.displayName;
        OIDC_SERVER_APPLICATION_URL = oidcCfg.provider.issuerUrl;
        OIDC_REDIRECT_URI = builtins.head serviceCfg.access.oidc.callbackURLs;
        OIDC_CLAIM_ROLES = lib.mkDefault "groups";
        OIDC_ROLE_ADMIN = lib.mkDefault cfg.groups.admin;
        OIDC_ROLE_EDITOR = lib.mkDefault cfg.groups.users;
        OIDC_ROLE_VIEWER = lib.mkDefault cfg.groups.guests;
      };
    };

    # Left off `services.romm.environmentFile` so the consumer keeps it for its own credentials:
    # systemd concatenates EnvironmentFile across definitions.
    systemd.services.romm.serviceConfig.EnvironmentFile = lib.mkIf federated [
      cfg.runtimeTemplates."romm.env".path
    ];

    # Default rather than fixed: a consumer fronting RomM with nginx itself replaces this wholesale.
    # The gateway owns :80, so the vhost binds the registered socket instead.
    services.nginx.virtualHosts.${rommCfg.nginx.virtualHost}.listen = lib.mkDefault [
      {
        addr = serviceCfg.host;
        inherit (serviceCfg) port;
      }
    ];
  };
}
