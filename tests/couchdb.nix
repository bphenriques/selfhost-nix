# CouchDB: enableSelfhostIntegration derives accounts and their databases from selfhost.users, and the
# `_up` healthcheck stays answerable without credentials while everything else requires them.
#
# The node also defines `services.couchdb.extraConfig.chttpd`, which is the regression: that option is
# types.attrs, so a consumer section replaces the app's rather than merging, and the app's
# require_valid_user would vanish with nothing failing until the database answered anonymously.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-couchdb";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ common ];

      selfhost = {
        apps.couchdb.enable = true;

        users.admin.services.couchdb = {
          enable = true;
          databases = [ "notes-admin" ];
        };
        users.guest = {
          email = "guest@test.local";
          firstName = "Gus";
          lastName = "Guest";
          groups = [ config.selfhost.groups.users ];
          auth.oidc.enable = false;
          # no services.couchdb.enable → no account, no database
        };

        runtimeSecrets."couchdb-admin-password".regenerateIfMissing = lib.mkForce true;
        runtimeSecrets."couchdb-password-admin".regenerateIfMissing = lib.mkForce true;
      };

      services.couchdb.extraConfig.chttpd.enable_cors = true;
    };

  testScript = ''
    machine.wait_for_unit("couchdb.service")
    machine.wait_for_unit("couchdb-configure.service")

    # It reconciled on the first try. CouchDB answers /_up before its system databases exist, so a
    # reconciler that waits on readiness alone 404s on the first user and only succeeds on the retry.
    machine.succeed("test \"$(systemctl show couchdb-configure.service -p NRestarts --value)\" = 0")

    creds = "-u admin:$(cat /var/lib/homelab-secrets/couchdb-admin-password)"

    # require_valid_user_except_for_up: the healthcheck answers unauthenticated, nothing else does.
    # Holds despite the consumer's own chttpd section (see header).
    machine.succeed("curl -sf http://127.0.0.1:5984/_up")
    machine.fail("curl -sf http://127.0.0.1:5984/_all_dbs")

    # Both survived the ini chain: the app's invariant and the consumer's own key in the same section.
    machine.succeed(
        f"curl -sf {creds} http://127.0.0.1:5984/_node/_local/_config/chttpd/require_valid_user | grep -q true"
    )
    machine.succeed(
        f"curl -sf {creds} http://127.0.0.1:5984/_node/_local/_config/chttpd/enable_cors | grep -q true"
    )

    # Only the opted-in user is provisioned, with their database owned by them.
    machine.succeed(f"curl -sf {creds} http://127.0.0.1:5984/_users/org.couchdb.user:admin")
    machine.fail(f"curl -sf {creds} http://127.0.0.1:5984/_users/org.couchdb.user:guest")
    machine.succeed(
        f"curl -sf {creds} http://127.0.0.1:5984/notes-admin/_security | grep -q '\"names\":\\[\"admin\"\\]'"
    )

    # Idempotent: a second run over existing users and databases still succeeds.
    machine.succeed("systemctl restart couchdb-configure.service")
  '';
}
