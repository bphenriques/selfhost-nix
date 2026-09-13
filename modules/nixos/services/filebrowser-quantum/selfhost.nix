# First-party FileBrowser Quantum app: drives the base module and wires it into the framework,
# deriving users and per-user SMB binds from selfhost.users grants.
{ config, lib, ... }:
let
  cfg = config.selfhost;
  app = cfg.apps.filebrowser-quantum;
  serviceCfg = cfg.services.filebrowser-quantum;
  oidcCfg = cfg.auth.oidc;
  smb = cfg.storage.mounts.smb.shares;
  fbRoot = config.services.filebrowser-quantum.source.path;
  unlistedScope = "/.unlisted";
  federated = serviceCfg.access.model == "oidc";

  enabledUsers = lib.filterAttrs (_: u: u.services.filebrowser-quantum.enable) cfg.users;
  grants = lib.concatLists (
    lib.mapAttrsToList (
      user: u:
      lib.mapAttrsToList (mount: perm: {
        inherit user mount;
        readOnly = perm == "ro";
      }) u.services.filebrowser-quantum.storage
    ) enabledUsers
  );
  bindSpec = g: "${smb.${g.mount}.localMount}:${fbRoot}/${g.user}/${g.mount}";
in
{
  options.selfhost = {
    apps.filebrowser-quantum = {
      enable = lib.mkEnableOption "the first-party FileBrowser Quantum app (per-user file sharing)";
      enableSelfhostIntegration = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Derive users and per-user SMB binds from selfhost.users grants and register behind the active gateway. Turn off to wire users, storage and auth yourself.";
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.services.filebrowser-quantum = {
            enable = lib.mkEnableOption "a FileBrowser entry for this user (access is gated by the service auth, not this flag)";
            storage = lib.mkOption {
              type = lib.types.attrsOf (
                lib.types.enum [
                  "ro"
                  "rw"
                ]
              );
              default = { };
              description = "selfhost SMB mounts this user may access, keyed by permission; unioned into their scope (read-write iff any is `rw`).";
            };
            admin = lib.mkEnableOption "FileBrowser admin";
          };
        }
      );
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.enable && app.enable) {
      selfhost = {
        services.filebrowser-quantum = {
          displayName = lib.mkDefault "File Browser";
          meta.homepage = lib.mkDefault "https://github.com/gtsteffaniak/filebrowser";
          meta.description = lib.mkDefault "File Browser";
          meta.category = lib.mkDefault "files";
          port = lib.mkDefault 8085;
          access.allowedGroups = lib.mkDefault [ cfg.groups.admin ];
          healthcheck.path = "/health";
          # Quantum can federate, so it only falls back to the gateway where no provider exists.
          access.model = lib.mkDefault (if oidcCfg.active then "oidc" else "forwardAuth");
          # Quantum serves the callback under its API, not the framework default path.
          access.oidc.callbackURLs = [ "${serviceCfg.publicUrl}/api/auth/oidc/callback" ];
          access.oidc.systemd.dependentServices = [ "filebrowser-quantum" ];
        };

        # The reconciler drives the API as this account; login is OIDC or the gateway either way.
        runtimeSecrets.filebrowser-quantum-admin-password.restartUnits = [
          "filebrowser-quantum.service"
          "filebrowser-quantum-configure.service"
        ];

        # Read from the environment because Quantum takes no `_FILE` paths for these.
        runtimeTemplates."filebrowser-quantum.env" = lib.mkIf federated {
          content = ''
            FILEBROWSER_OIDC_CLIENT_ID=${cfg.oidcPlaceholder.filebrowser-quantum.id}
            FILEBROWSER_OIDC_CLIENT_SECRET=${cfg.oidcPlaceholder.filebrowser-quantum.secret}
          '';
          restartUnits = [ "filebrowser-quantum.service" ];
        };
      };

      services.filebrowser-quantum = {
        enable = true;
        adminPasswordFile = cfg.runtimeSecrets.filebrowser-quantum-admin-password.path;
        loginMethod = if federated then "oidc" else "proxy";
        unlistedScope = lib.mkDefault unlistedScope;
        settings.server = {
          listen = serviceCfg.host;
          inherit (serviceCfg) port;
        };
      };

      systemd.services.filebrowser-quantum.serviceConfig = lib.mkIf federated {
        EnvironmentFile = [ cfg.runtimeTemplates."filebrowser-quantum.env".path ];
        SupplementaryGroups = serviceCfg.access.oidc.systemd.supplementaryGroups;
      };
    })

    (lib.mkIf (cfg.enable && app.enable && federated) {
      services.filebrowser-quantum.settings.auth.methods.oidc = {
        issuerUrl = oidcCfg.provider.issuerUrl;
        scopes = "openid email profile groups";
        userIdentifier = "preferred_username";
        groupsClaim = "groups";
        # Enforced in the app too, so a valid token from outside the groups is still refused.
        # Empty means any authenticated principal, which is upstream's default.
        userGroups = serviceCfg.access.allowedGroups;
        logoutRedirectUrl = lib.mkDefault "${serviceCfg.publicUrl}/";
      };
    })

    (lib.mkIf (cfg.enable && app.enable && app.enableSelfhostIntegration) {
      warnings = lib.mapAttrsToList (
        name: _: "selfhost.users.${name}.services.filebrowser-quantum is enabled with no storage grants — empty FileBrowser."
      ) (lib.filterAttrs (_: u: u.services.filebrowser-quantum.storage == { }) enabledUsers);

      # Every listed user needs their scope to exist: grants bind *into* it, so a user with none would
      # otherwise fail the scope check for everyone. The unlisted scope stays empty and unwritable.
      systemd.tmpfiles.settings.filebrowser-quantum-selfhost =
        lib.mapAttrs' (
          name: _:
          lib.nameValuePair "${fbRoot}/${name}" {
            d = {
              inherit (config.services.filebrowser-quantum) user group;
              mode = "0750";
            };
          }
        ) enabledUsers
        // lib.optionalAttrs (config.services.filebrowser-quantum.unlistedScope == unlistedScope) {
          "${fbRoot}${unlistedScope}".d = {
            inherit (config.services.filebrowser-quantum) user group;
            mode = "0555";
          };
        };

      services.filebrowser-quantum.users = lib.mapAttrs (user: u: {
        scope = "/${user}";
        readOnly = !(lib.elem "rw" (lib.attrValues u.services.filebrowser-quantum.storage));
        inherit (u.services.filebrowser-quantum) admin;
      }) enabledUsers;

      selfhost.services.filebrowser-quantum.storage.mounts = lib.unique (map (g: g.mount) grants);

      # ro grants get a ro bind that can't be bypassed (same namespace, never re-bound).
      systemd.services.filebrowser-quantum.serviceConfig = {
        BindPaths = map bindSpec (lib.filter (g: !g.readOnly) grants);
        BindReadOnlyPaths = map bindSpec (lib.filter (g: g.readOnly) grants);
      };
    })
  ];
}
