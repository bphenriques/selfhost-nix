# Radicale's per-service-account surface, beside the app like ./user.nix. Access comes from the owner's grant.
{ lib, ... }:
{
  options.selfhost.serviceAccounts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.services.radicale = {
          enable = lib.mkEnableOption "a Radicale login for this service account";

          passwordFile = lib.mkOption {
            type = lib.types.str;
            description = "File holding the login's password, which its client elsewhere also needs.";
          };
        };
      }
    );
  };
}
