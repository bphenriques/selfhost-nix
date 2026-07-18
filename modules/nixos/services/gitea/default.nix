# First-party Gitea app: a git server fronted by OIDC. Human accounts and the OIDC auth source are
# provisioned via the stable `gitea admin` CLI; non-UI service accounts get SSH keys registered through
# the admin API (the CLI can't add keys) using an ephemeral admin token the configure mints itself.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.gitea;
  serviceCfg = config.selfhost.services.gitea;
  oidcCfg = config.selfhost.auth.oidc;

  enabledUsers = lib.filterAttrs (_: u: u.apps.gitea.enable) config.selfhost.users;
  serviceAccounts = lib.filterAttrs (_: a: a.enable) app.serviceAccounts;

  userListFile = pkgs.writeText "gitea-users.json" (
    builtins.toJSON (
      (lib.mapAttrsToList (_: u: {
        inherit (u)
          username
          email
          firstName
          lastName
          ;
        isAdmin = u.apps.gitea.admin;
        sshKeys = [ ];
      }) enabledUsers)
      ++ (lib.mapAttrsToList (name: a: {
        username = name;
        email = "${name}@service.localhost";
        firstName = name;
        lastName = "Service";
        isAdmin = false;
        sshKeys = map (k: { inherit (k) key readOnly; }) a.sshKeys;
      }) serviceAccounts)
    )
  );

  gitea-configure = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "gitea-configure";
    runtimeInputs = [ config.services.gitea.package ];
    script = ./configure.nu;
  };

  # Provisions only the OIDC auth source; runs in gitea's preStart (see below).
  gitea-oidc-source = (import ../../builders.nix { inherit pkgs lib; }).writeNushellApplication {
    name = "gitea-oidc-source";
    runtimeInputs = [ config.services.gitea.package ];
    script = ./oidc-source.nu;
  };
in
{
  imports = [ ./user.nix ];

  options.selfhost = {
    apps.gitea.enable = lib.mkEnableOption "the first-party Gitea app (git server with OIDC login)";

    apps.gitea.ssh = {
      enable = lib.mkEnableOption "Gitea's built-in SSH server for git-over-SSH (off by default — exposes a TCP port; HTTPS git works without it)";
      port = lib.mkOption {
        type = lib.types.port;
        default = 2222;
        description = "Listen port for the built-in SSH server.";
      };
      openFirewall = lib.mkEnableOption "opening the SSH port in the firewall (all interfaces); leave off to scope it yourself";
    };

    apps.gitea.serviceAccounts = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "this non-UI Gitea account" // {
              default = true;
            };
            sshKeys = lib.mkOption {
              type = lib.types.listOf (
                lib.types.submodule {
                  options = {
                    key = lib.mkOption {
                      type = lib.types.str;
                      description = "Public key in authorized_keys format.";
                    };
                    readOnly = lib.mkOption {
                      type = lib.types.bool;
                      default = false;
                      description = "Register as a read-only (deploy) key.";
                    };
                  };
                }
              );
              default = [ ];
              description = "SSH keys for git-over-SSH; registered via the admin API on account creation.";
            };
          };
        }
      );
      default = { };
      description = "Non-human Gitea accounts (CI/bots), provisioned via the gitea CLI.";
    };
  };

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost = {
      services.gitea = {
        displayName = lib.mkDefault "Gitea";
        description = lib.mkDefault "Git Server";
        port = lib.mkDefault 3100;
        subdomain = lib.mkDefault "git";
        access.allowedGroups = lib.mkDefault [ config.selfhost.groups.admin ];
        oidc = {
          enable = true;
          callbackURLs = [ "${serviceCfg.publicUrl}/user/oauth2/${oidcCfg.provider.internalName}/callback" ];
          systemd.dependentServices = [
            "gitea"
            "gitea-configure"
          ];
        };
        healthcheck.path = "/api/healthz";

        backup = {
          package = pkgs.writeShellApplication {
            name = "backup-gitea";
            text = ''cp -a "${config.services.gitea.repositoryRoot}/." "$OUTPUT_DIR/"'';
          };
          after = [ "gitea.service" ];
        };
      };

      # Break-glass local admin (routine login is OIDC); reconciled each configure run, so the default
      # regenerateIfMissing is safe (a lost file self-heals rather than drifting from the DB).
      runtimeSecrets.gitea-admin-password = {
        owner = "gitea";
        restartUnits = [ "gitea-configure.service" ];
      };
    };

    services.gitea = {
      enable = true;
      database.type = "sqlite3";
      settings = {
        server = {
          HTTP_ADDR = "127.0.0.1";
          HTTP_PORT = serviceCfg.port;
          ROOT_URL = serviceCfg.publicUrl;
          DOMAIN = serviceCfg.publicHost;
        }
        // lib.optionalAttrs app.ssh.enable {
          START_SSH_SERVER = true;
          SSH_LISTEN_HOST = "0.0.0.0";
          SSH_LISTEN_PORT = app.ssh.port;
          SSH_PORT = app.ssh.port;
        };
        service = {
          DISABLE_REGISTRATION = true;
          ENABLE_NOTIFY_MAIL = false;
          ENABLE_BASIC_AUTHENTICATION = false;
        };
        session.PROVIDER = "file";
        oauth2.ENABLED = false; # Gitea is an OIDC client, not a provider.
        oauth2_client = {
          ENABLE_AUTO_REGISTRATION = true;
          USERNAME = "nickname";
          ACCOUNT_LINKING = "auto";
          UPDATE_AVATAR = true;
        };
        openid = {
          ENABLE_OPENID_SIGNIN = false;
          ENABLE_OPENID_SIGNUP = false;
        };
        repository = {
          DEFAULT_PRIVATE = "private";
          ENABLE_PUSH_CREATE_USER = true;
        };
        ui.DEFAULT_THEME = "gitea-dark";
        mailer.ENABLED = false;
        packages.ENABLED = false;
        "cron.update_checker".ENABLED = false;
        indexer.REPO_INDEXER_ENABLED = false;
        other.SHOW_FOOTER_VERSION = false;
        actions.ENABLED = false;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf (app.ssh.enable && app.ssh.openFirewall) [ app.ssh.port ];

    # Provision the OIDC source into the DB before the server registers providers (after nixpkgs' preStart).
    # Non-fatal: gitea's server fail-soft-skips an unreachable source (first boot before the cert), so we
    # mustn't be stricter — let it start; the next start provisions.
    systemd.services.gitea = {
      serviceConfig.SupplementaryGroups = serviceCfg.oidc.systemd.supplementaryGroups;
      environment = {
        OIDC_PROVIDER_NAME = oidcCfg.provider.internalName;
        OIDC_DISCOVERY_URL = oidcCfg.provider.discoveryUrl;
        OIDC_CLIENT_ID_FILE = serviceCfg.oidc.id.file;
        OIDC_CLIENT_SECRET_FILE = serviceCfg.oidc.secret.file;
      };
      preStart = lib.mkAfter ''
        ${lib.getExe gitea-oidc-source} || echo "gitea-oidc-source: OIDC provider unreachable; starting without the source (will retry next start)"
      '';
    };

    systemd.services.gitea-configure = {
      description = "Gitea setup (admin, users, service-account keys, admin reconcile)";
      wantedBy = [ "gitea.service" ];
      after = [ "gitea.service" ];
      requires = [ "gitea.service" ];
      partOf = [ "gitea.service" ];
      restartTriggers = [
        userListFile
        gitea-configure
      ];
      startLimitIntervalSec = 300;
      startLimitBurst = 3;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 600;
        Restart = "on-failure";
        RestartSec = 10;
        User = config.services.gitea.user;
        Group = config.services.gitea.group;
        WorkingDirectory = config.services.gitea.stateDir;
        SupplementaryGroups = serviceCfg.oidc.systemd.supplementaryGroups;
      };
      environment = {
        GITEA_URL = serviceCfg.url;
        GITEA_ADMIN_PASSWORD_FILE = config.selfhost.runtimeSecrets.gitea-admin-password.path;
        GITEA_CONFIG = "${config.services.gitea.stateDir}/custom/conf/app.ini";
        GITEA_USERS_FILE = userListFile;
      };
      path = [ config.services.gitea.package ];
      script = lib.getExe gitea-configure;
    };
  };
}
