# A framework user. The attribute name in settings.nix (`admin`) is the username; `isAdmin` is derived
# from membership in the admin group. Per-app access goes under `apps.<name>`.
{
  email = "admin@example.com";
  firstName = "Admin";
  lastName = "User";
  groups = [ "admin" ];

  auth.oidc.enable = true; # provision an OIDC account in Pocket-ID

  apps.radicale.enable = true; # this user gets a Radicale (CalDAV/CardDAV) account
}
