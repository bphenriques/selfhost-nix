# Gitea's per-service-account surface, beside the app like ./user.nix.
{ lib, ... }:
{
  options.selfhost.serviceAccounts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.services.gitea = {
          enable = lib.mkEnableOption "a non-UI Gitea account for this service account";

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
  };
}
