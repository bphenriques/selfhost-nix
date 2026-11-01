# Provisions Pocket-ID users/groups/clients via the pocket-id-manage CLI.
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.selfhost;
  serviceCfg = config.selfhost.services.pocket-id;
  oidcCfg = config.selfhost.auth.oidc;

  # Local rather than on `auth.oidc.provider`: how an implementation authenticates to itself is not the contract.
  apiKeyFile = cfg.runtimeSecrets.pocket-id-api-key.path;
  smtpCfg = config.selfhost.mail;

  baseServiceName = "pocket-id-provision-base";

  usersConfigFile = pkgs.writeText "oidc-provision-users-config.json" (
    builtins.toJSON {
      inherit (oidcCfg.provisionConfig) users groups;
      # The whole declared client set, so base provisioning can find what Pocket-ID holds that Nix no longer asks for.
      clients = lib.attrNames oidcCfg.clients;
    }
  );

  mkClientConfigFile =
    name: client:
    pkgs.writeText "oidc-client-config-${name}.json" (
      builtins.toJSON {
        inherit (client)
          name
          callbackURLs
          pkce
          allowedGroups
          ;
      }
    );

  pocketIdManage = pkgs.writeShellApplication {
    name = "pocket-id-manage";
    runtimeInputs = [ pkgs.selfhost.pocket-id-manage ];
    text = ''
      export POCKET_ID_URL="${serviceCfg.url}"
      export POCKET_ID_API_KEY_FILE="${apiKeyFile}"
      export POCKET_ID_GUESTS_GROUP="${cfg.groups.guests}"
      exec pocket-id-manage-bin "$@"
    '';
  };

  hardenedServiceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    Restart = "on-failure";
    RestartSec = 10;
    UMask = "0077";
    PrivateTmp = true;
    ProtectSystem = "strict";
    ReadWritePaths = [ oidcCfg.credentials.dir ];
    ProtectHome = true;
    NoNewPrivileges = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    RestrictAddressFamilies = [
      "AF_INET"
      "AF_INET6"
      "AF_UNIX"
    ];
  };
in
{
  options.selfhost.auth.oidc.pocket-id = {
    enable = lib.mkEnableOption "Pocket-ID OIDC implementation";
  };

  config = lib.mkIf cfg.auth.oidc.pocket-id.enable {
    selfhost = {
      services.pocket-id = {
        displayName = lib.mkDefault "Pocket ID";
        meta.homepage = lib.mkDefault "https://pocket-id.org";
        meta.description = lib.mkDefault "OIDC Provider";
        meta.category = lib.mkDefault "identity";
        subdomain = lib.mkDefault "auth";
        port = lib.mkDefault 8094;
        healthcheck.path = "/health";
      };

      auth.oidc.provider = {
        displayName = "Pocket-ID";
        internalName = "PocketID";
        issuerUrl = serviceCfg.publicUrl;
      };

      auth.oidc.systemd = {
        baseProvisionUnit = "${baseServiceName}.service";
        clientProvisionUnitPrefix = "pocket-id-provision-client-";
      };

      # A broken OIDC provision only shows at the next login, so failures alert (bounded by startLimitBurst).
      tasks.oidc-provision.systemdServices = [
        baseServiceName
      ]
      ++ map (name: "pocket-id-provision-client-${name}") (lib.attrNames oidcCfg.clients);

      runtimeSecrets = {
        # Encrypts the DB, so a lost key over a surviving DB stays absent rather than orphaning it.
        pocket-id-encryption-key = {
          owner = config.services.pocket-id.user;
          onMissing.generateOnce = config.services.pocket-id.dataDir;
          restartUnits = [ "pocket-id.service" ];
        };
        pocket-id-api-key = {
          owner = config.services.pocket-id.user;
          restartUnits = [ "pocket-id.service" ];
        };
      };
    };

    services.pocket-id = {
      enable = true;
      settings = {
        APP_URL = serviceCfg.publicUrl;
        PORT = serviceCfg.port;
        HOST = "127.0.0.1";
        TRUST_PROXY = true;
        ANALYTICS_DISABLED = true;
        ENCRYPTION_KEY_FILE = cfg.runtimeSecrets.pocket-id-encryption-key.path;
        STATIC_API_KEY_FILE = apiKeyFile;
        UI_CONFIG_DISABLED = true;
        # pocket-id-manage mints each client's secret itself; an auto-created one would be live and unrecorded.
        AUTO_CREATE_OIDC_CLIENT_SECRET = false;

        # Invite only
        ALLOW_USER_SIGNUPS = "withToken";
        EMAILS_VERIFIED = true;
        EMAIL_VERIFICATION_ENABLED = false;
        EMAIL_ONE_TIME_ACCESS_AS_ADMIN_ENABLED = true;
        EMAIL_ONE_TIME_ACCESS_AS_UNAUTHENTICATED_ENABLED = false;
      }
      # SMTP is optional: `pocket-id one-time-access-token <user>` mints enrolment links without it.
      // lib.optionalAttrs smtpCfg.active {
        SMTP_HOST = smtpCfg.host;
        SMTP_PORT = toString smtpCfg.port;
        SMTP_FROM = smtpCfg.from;
        SMTP_USER = smtpCfg.user;
        SMTP_TLS = smtpCfg.tls;
        SMTP_PASSWORD_FILE = smtpCfg.passwordFile;
      };
    };

    # Credentials base dir (persistent); 0755 so services can traverse to their own 0750 client subdirs.
    systemd.tmpfiles.rules = [
      "d ${oidcCfg.credentials.dir} 0755 root root -"
    ];

    systemd.services = {
      ${baseServiceName} = {
        description = "Pocket-ID users and groups provisioning";
        wantedBy = [ "pocket-id.service" ];
        after = [
          "network-online.target"
          "pocket-id.service"
        ];
        wants = [ "network-online.target" ];
        requires = [ "pocket-id.service" ];
        partOf = [ "pocket-id.service" ];
        restartTriggers = [ usersConfigFile ];
        startLimitIntervalSec = 300;
        startLimitBurst = 3;
        environment = {
          OIDC_CONFIG_FILE = toString usersConfigFile;
          OIDC_CREDENTIALS_DIR = oidcCfg.credentials.dir;
        };
        serviceConfig = hardenedServiceConfig;
        path = [ pocketIdManage ];
        script = "pocket-id-manage provision-users";
      };
    }
    // lib.mapAttrs' (
      name: client:
      let
        clientConfigFile = mkClientConfigFile name client;
      in
      lib.nameValuePair "pocket-id-provision-client-${name}" {
        description = "Pocket-ID OIDC client provisioning for ${name}";
        wantedBy = [ "pocket-id.service" ];
        after = [
          "network-online.target"
          "pocket-id.service"
          "${baseServiceName}.service"
        ];
        wants = [ "network-online.target" ];
        requires = [
          "pocket-id.service"
          "${baseServiceName}.service"
        ];
        partOf = [ "pocket-id.service" ];
        restartTriggers = [ clientConfigFile ];
        startLimitIntervalSec = 300;
        startLimitBurst = 3;
        environment = {
          OIDC_CLIENT_CONFIG_FILE = toString clientConfigFile;
          OIDC_CREDENTIALS_DIR = oidcCfg.credentials.dir;
        };
        serviceConfig = hardenedServiceConfig;
        path = [ pocketIdManage ];
        script = "pocket-id-manage provision-client";
      }
    ) oidcCfg.clients;

    environment.systemPackages = [ pocketIdManage ];
  };
}
