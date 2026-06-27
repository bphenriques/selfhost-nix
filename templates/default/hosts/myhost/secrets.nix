# The only backend-specific file. selfhost-nix reads secret *paths*, so to move off sops (to agenix, plain
# files, …) you change only this module. Encrypted values live in the private flake's secrets.yaml.
{ config, private, ... }:
{
  sops = {
    defaultSopsFile = private.sopsSecretsFile;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]; # decrypt with the host key

    secrets.cloudflare-dns-token = { };
    secrets.smtp-password.owner = config.services.pocket-id.user; # Pocket-ID reads it directly

    templates."traefik-cloudflare" = {
      owner = "traefik";
      content = ''
        CF_DNS_API_TOKEN=${config.sops.placeholder.cloudflare-dns-token}
      '';
    };
  };

  # Hand the framework the resolved paths.
  selfhost.mail.passwordFile = config.sops.secrets.smtp-password.path;
  selfhost.ingress.acme.credentialsEnvFile = config.sops.templates."traefik-cloudflare".path;
}
