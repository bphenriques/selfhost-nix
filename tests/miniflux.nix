# Miniflux: the per-user settings reconcile (configure.nu) applies a preference through the partial-update
# PUT. The bootstrap admin doubles as the reconcile target — a real user is OIDC-provisioned on first login,
# which a VM can't drive. Pocket-ID provisions the client so miniflux starts; no OIDC login is performed.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-miniflux";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ common ];
      selfhost = {
        mail = {
          host = "smtp.test.local";
          port = 587;
          from = "admin@test.local";
          user = "admin@test.local";
          tls = "starttls";
          passwordFile = builtins.toFile "smtp-pw" "dummy";
        };
        auth.oidc.pocket-id.enable = true;
        apps.miniflux.enable = true;

        # Make the bootstrap admin ("admin") a reconcile target with a distinctive preference.
        users.admin.auth.oidc.enable = lib.mkForce true;
        users.admin.services.miniflux.settings.theme = "dark_serif";
      };
    };

  testScript = ''
    machine.wait_for_unit("pocket-id.service")
    machine.wait_for_unit("miniflux.service")
    machine.wait_for_unit("miniflux-configure.service")

    # configure.nu PUT the admin's freeform preference via the API; the reconcile only touches an existing
    # user (the bootstrap admin), so the change reflects back through /v1/users.
    pw = machine.succeed("cat /var/lib/homelab-secrets/miniflux-admin-password").strip()
    machine.wait_until_succeeds(
        f"curl -sf -u admin:{pw} http://127.0.0.1:8081/v1/users | grep -q dark_serif",
        timeout=60,
    )
  '';
}
