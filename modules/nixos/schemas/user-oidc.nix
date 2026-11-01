{ lib, ... }:
{
  options.auth.oidc = {
    enable = lib.mkEnableOption "OIDC account for this user" // {
      default = true;
    };

    # Off by default: mailing the enrolment link to a placeholder address fails provisioning for everyone.
    inviteByEmail = lib.mkEnableOption "emailing this user a one-time enrolment link when the account is first created; otherwise provisioning prints the command to mint one";
  };
}
