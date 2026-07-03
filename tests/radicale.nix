# Radicale: enableSelfhostIntegration derives the htpasswd from selfhost.users (enabled user in, others out).
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-radicale";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ common ];

      selfhost = {
        apps.radicale.enable = true;

        users.admin.apps.radicale.enable = true; # the base admin opts in
        users.guest = {
          email = "guest@test.local";
          firstName = "Gus";
          lastName = "Guest";
          groups = [ config.selfhost.groups.users ];
          auth.oidc.enable = false;
          # no apps.radicale.enable → must be absent from the htpasswd
        };

        runtimeSecrets."radicale-password-admin".regenerateIfMissing = lib.mkForce true;
      };
    };

  testScript = ''
    machine.wait_for_unit("radicale-configure.service")
    machine.wait_for_unit("radicale.service")

    # Only the opted-in user is provisioned.
    machine.succeed("grep -q '^admin:' /var/lib/radicale/users")
    machine.fail("grep -q '^guest:' /var/lib/radicale/users")

    # The configure completed on the first try (RemainAfterExit oneshot, ordered before radicale) — no
    # crash-restart loop while deriving the htpasswd.
    machine.succeed("test \"$(systemctl show radicale-configure.service -p NRestarts --value)\" = 0")
  '';
}
