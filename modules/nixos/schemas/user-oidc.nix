{ lib, ... }:
{
  options.auth.oidc.enable = lib.mkEnableOption "OIDC account for this user" // {
    default = true;
  };
}
