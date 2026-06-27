# Gitea + a real Pocket-ID, no ingress: the OIDC discovery is unreachable, so gitea must still start
# (non-fatal provisioning). Also guards admin reconcile, token revoke, SSH-off, and the OIDC-linked
# source-preserve edge.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-gitea";

  nodes.machine =
    { config, pkgs, ... }:
    {
      imports = [ common ];

      environment.systemPackages = [ pkgs.sqlite ]; # for the OIDC-linked DB simulation below

      selfhost = {

        # Pocket-ID needs mail configured; nothing is actually sent in this test.
        mail = {
          host = "smtp.test.local";
          port = 587;
          from = "admin@test.local";
          user = "admin@test.local";
          tls = "starttls";
          passwordFile = builtins.toFile "smtp-pw" "dummy";
        };

        auth.oidc.pocket-id.enable = true;
        apps.gitea.enable = true;

        # A non-fleet-admin user promoted to gitea site-admin via the per-app override (the base `admin`
        # collides with gitea's bootstrap superuser, and the framework allows only one fleet admin). This
        # exercises both the override and the promote-via-admin-API path.
        users.alice = {
          email = "alice@test.local";
          firstName = "Alice";
          lastName = "User";
          groups = [ config.selfhost.groups.users ];
          auth.oidc.enable = false;
          apps.gitea = {
            enable = true;
            admin = true; # override: gitea site-admin without being a fleet admin
          };
        };
      };
    };

  testScript =
    { nodes, ... }:
    let
      gitea = "${nodes.machine.services.gitea.package}/bin/gitea -c /var/lib/gitea/custom/conf/app.ini";
    in
    ''
      machine.wait_for_unit("pocket-id.service")
      machine.wait_for_unit("pocket-id-provision-client-gitea.service")

      # gitea starts even though the OIDC discovery is unreachable (no ingress here): provisioning is
      # non-fatal, so the cert-race that blocked first boot no longer does.
      machine.wait_for_unit("gitea.service")
      machine.wait_for_unit("gitea-configure.service")
      machine.succeed("journalctl -u gitea.service | grep -q 'OIDC provider unreachable'")

      # alice reconciled to site-admin from the fleet isAdmin — proves the admin-API PATCH works here.
      machine.succeed("runuser -u gitea -- ${gitea} admin user list --admin | grep -qw alice")

      # the ephemeral admin token was minted and revoked.
      machine.succeed("journalctl -u gitea-configure.service | grep -q 'Revoked ephemeral admin token'")

      # the built-in SSH server is off by default — nothing listening on 2222.
      machine.fail("ss -tlnH 'sport = :2222' | grep -q ':2222'")

      # OIDC-linked edge: a non-local account must keep its auth source through an admin change. Add a real
      # source, mark alice as linked to it (login_type 3) and not-admin, then re-run the reconcile — it must
      # re-promote her while preserving source_id (the fix echoes the real value, never resetting to 0/unlink).
      machine.succeed("runuser -u gitea -- ${gitea} admin auth add-smtp --name ext --host localhost --port 587 --skip-verify")
      src = machine.succeed("runuser -u gitea -- ${gitea} admin auth list --vertical-bars | grep -w ext | cut -d'|' -f1 | tr -d ' '").strip()
      db = "/var/lib/gitea/data/gitea.db"
      machine.succeed("sqlite3 " + db + " \"UPDATE user SET login_source=" + src + ", login_type=3, login_name='alice-ext', is_admin=0 WHERE name='alice'\"")
      machine.systemctl("restart gitea-configure.service")
      machine.wait_for_unit("gitea-configure.service")
      row = machine.succeed("sqlite3 " + db + " \"SELECT is_admin || '|' || login_source || '|' || login_type FROM user WHERE name='alice'\"").strip()
      assert row == "1|" + src + "|3", f"alice should be re-promoted with her source preserved, got: {row} (src={src})"
    '';
}
