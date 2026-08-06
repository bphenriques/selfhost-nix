# Immich's per-user surface, kept beside the app rather than in core's user schema.
{ lib, ... }:
let
  libraryModule = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.str;
        description = "Library name as shown in Immich; also its reconcile identity, so renaming creates a new one.";
      };

      importPaths = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Directories Immich scans for this library. The app grants the service write access to them.";
      };

      exclusionPatterns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Glob patterns skipped during the scan.";
      };
    };
  };
in
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { config, ... }:
        {
          options.services.immich = {
            enable = lib.mkEnableOption "an Immich account for this user";

            admin = lib.mkOption {
              type = lib.types.bool;
              default = config.isAdmin;
              defaultText = lib.literalMD "the user's `isAdmin`";
              description = "Grant this account Immich administrator rights.";
            };

            passwordFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Path to a file holding the initial password, applied at account creation and never reconciled. Null generates a random one, for accounts that sign in through OIDC.";
            };

            quotaBytes = lib.mkOption {
              type = lib.types.nullOr lib.types.ints.unsigned;
              default = null;
              example = 107374182400;
              description = "Upload quota for this account in bytes. Null is unlimited. Reconciled, so changing it moves the existing account's quota.";
            };

            storageLabel = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Folder name for this account under a `{{label}}` storage template. Null falls back to the account's UUID. Reconciled.";
            };

            libraries = lib.mkOption {
              type = lib.types.listOf libraryModule;
              default = [ ];
              description = "External libraries owned by this user: existing directories Immich scans in place. Empty leaves the account upload-only, which is the common case.";
            };
          };
        }
      )
    );
  };
}
