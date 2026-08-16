let
  admin = import ./users/admin.nix;
in
{
  domain = "example.com"; # your domain; apps are served at <subdomain>.<domain>
  acme.email = admin.email; # Let's Encrypt registration/expiry email

  # Interfaces HTTP/HTTPS is reachable on — your LAN link, and the WireGuard one if you run it.
  # Name them: leaving this empty opens 80/443 on every interface, which this project does not recommend.
  allowedInterfaces = [ "eth0" ];

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
