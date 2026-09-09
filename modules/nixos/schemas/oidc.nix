{
  name,
  config,
  lib,
  ...
}:
let
  serviceConfig = config;
  credentialsBaseDir = "/var/lib/homelab-oidc"; # persistent; see auth/oidc.nix for the rationale
in
{
  options.access.oidc = lib.mkOption {
    type = lib.types.submodule (
      { config, ... }: {
        options = {
          # Only the file paths live here. A template embedding these values uses
          # `selfhost.oidcPlaceholder.<client>.{id,secret}`, which is the scheme the renderer substitutes.
          id.file = lib.mkOption {
            type = lib.types.str;
            default = "${credentialsBaseDir}/${name}/id";
            readOnly = true;
            description = "Path to the file containing the client ID";
          };

          secret.file = lib.mkOption {
            type = lib.types.str;
            default = "${credentialsBaseDir}/${name}/secret";
            readOnly = true;
            description = "Path to the file containing the client secret";
          };

          name = lib.mkOption {
            type = lib.types.str;
            default = name;
            description = "Display name of the OIDC client in the provider";
          };

          callbackURLs = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "${serviceConfig.publicUrl}/oauth2/oidc/callback" ];
            defaultText = lib.literalMD "`[ <publicUrl>/oauth2/oidc/callback ]`";
            description = "Callback URLs for the OIDC client";
          };

          pkce = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Enable PKCE for this client";
          };

          gid = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = "Fixed GID for the credentials group (null = auto-assign)";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "homelab-oidc-${name}";
            readOnly = true;
            description = "Group name for this client's credentials";
          };

          systemd = {
            dependentServices = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Systemd services needing this client's credentials; auto-wired requires/after/partOf.";
            };

            loadCredentials = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [
                "oidc-id:${config.id.file}"
                "oidc-secret:${config.secret.file}"
              ];
              readOnly = true;
              description = "Ready-to-use LoadCredential entries for systemd services";
            };

            supplementaryGroups = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ config.group ];
              readOnly = true;
              description = "Groups to add for direct credential file access";
            };
          };
        };
      }
    );
    default = { };
    description = "OIDC client configuration, provisioned when `access.model = \"oidc\"`.";
  };
}
