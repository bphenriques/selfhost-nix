let
  admin = import ./users/admin.nix;
in
{
  domain = "example.com"; # your domain; apps are served at <subdomain>.<domain>
  acme.email = admin.email; # Let's Encrypt registration/expiry email

  smtp = {
    host = "smtp.example.com";
    port = 587;
    from = admin.email;
    user = admin.email;
    tls = "starttls";
  };

  # Framework users, keyed by username. Add more under ./users/.
  users = { inherit admin; };
}
