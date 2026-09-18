{ lib, ... }:
{
  options.auth.oidc = {
    enable = lib.mkEnableOption "OIDC account for this user" // {
      default = true;
    };

    # Off by default: the enrolment link is the account's first credential, and mailing it to a
    # placeholder address either bounces or fails provisioning for everyone else in the same run.
    inviteByEmail = lib.mkEnableOption "emailing this user a one-time enrolment link when the account is first created; otherwise provisioning prints the command to mint one";
  };
}
