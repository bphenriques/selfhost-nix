# Explicit module set (schemas are composed into the service registry, not imported here).
{
  imports = [
    ./services-registry.nix
    ./tasks-registry.nix
    ./users.nix
    ./resource-control.nix
    ./runtime-secrets.nix
    ./homepage.nix

    ./ingress/traefik.nix
    ./auth/oidc.nix
    ./auth/forwardauth.nix
    ./auth/pocket-id.nix
    ./auth/tinyauth.nix
    ./vpn/wireguard.nix
    ./storage/smb.nix
    ./mail/mail.nix
    ./monitoring/monitoring.nix
    ./backup/backup.nix
    ./notify/notify.nix
    ./notify/ntfy.nix
  ];
}
