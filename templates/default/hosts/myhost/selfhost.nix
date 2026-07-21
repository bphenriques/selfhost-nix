# Pure selfhost.* config: secret paths are filled in by secrets.nix, identity/domain by the private flake.
{ private, ... }:
{
  selfhost = {
    enable = true;
    inherit (private.settings) domain;

    # OIDC provider (Pocket-ID) for app logins, plus a forward-auth gate for apps without native OIDC.
    auth.oidc.pocket-id.enable = true;
    auth.forwardAuth.tinyauth.enable = true;

    # Outbound mail (Pocket-ID invites, alerts). Host/user/from from private; passwordFile → secrets.nix.
    mail = private.settings.smtp;

    # Public entry: Traefik terminates TLS via an ACME DNS-01 challenge. The DNS token → secrets.nix.
    ingress = {
      traefik.enable = true;
      acme = {
        dnsProvider = "cloudflare";
        email = private.settings.acme.email;
      };
    };

    # One example app. Add more under selfhost.apps.<name>; grant per-user access on
    # selfhost.users.<name>.services.<name> (see the private user file).
    apps.radicale.enable = true;

    # Framework users (identity, groups, OIDC opt-in) come from the private flake.
    users = private.settings.users;
  };
}
