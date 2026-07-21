# Explicit module set (schemas are composed into the service registry, not imported here).
{
  imports = [
    ./services-registry.nix
    ./tasks-registry.nix
    ./users.nix
    ./runtime-secrets.nix
    ./inventory.nix
    ./dashboards/tiles.nix

    ./ingress/ingress.nix
    ./ingress/traefik.nix
    ./auth/oidc.nix
    ./auth/forwardauth.nix
    ./auth/pocket-id.nix
    ./auth/oidc-rotation.nix
    ./auth/tinyauth.nix
    ./storage/smb.nix
    ./mail/mail.nix
    ./monitoring/monitoring.nix
    ./monitoring/alertmanager.nix
    ./backup/backup.nix
    ./notify/notify.nix
    ./notify/ntfy.nix

    # First-party apps (selfhost.apps.<name>): bundled apps on top of the framework, each default-off.
    ./services/arr
    ./services/bentopdf
    ./services/desec
    ./services/filebrowser
    ./services/filebrowser/selfhost.nix
    ./services/gitea
    ./services/homepage
    ./services/miniflux
    ./services/radicale
    ./services/transmission
    ./services/wireguard
  ];
}
