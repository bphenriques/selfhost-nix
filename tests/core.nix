# Core smoke test: registry + runtime-secrets + the ntfy provider provision cleanly — the publisher token
# lands root-owned 0400 (non-root consumers read it via LoadCredential) — and a generate-once secret whose
# regeneration is gated on the presence of the data it protects (generateOnceGuard).
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-core";

  nodes.machine = {
    imports = [ common ];

    selfhost = {
      notify.ntfy.enable = true;
      notify.topics.probes.public = false;

      # Generate-once secret guarded on a data dir the test controls (nothing else writes there).
      runtimeSecrets.test-guarded = {
        generateOnce = true;
        generateOnceGuard = "/var/lib/guard-data";
      };

      # A task publisher (not a system user) — its token is still provisioned root-owned, no chown gymnastics.
      tasks.probe = {
        systemdServices = [ "probe-dummy" ];
        integrations.notify = {
          enable = true;
          topic = "probes";
        };
      };
    };

    systemd.services.probe-dummy.serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };
  };

  testScript = ''
    # Runtime secret generated out-of-store with the declared mode.
    machine.wait_for_unit("homelab-runtime-secrets.service")
    machine.succeed("stat -c %a /var/lib/homelab-secrets/ntfy-admin-password | grep -qx 400")

    # ntfy provisions in one shot — no failed-then-restarted units.
    machine.wait_for_unit("ntfy-sh.service")
    machine.wait_for_unit("ntfy-configure.service")
    restarts = machine.succeed("systemctl show ntfy-configure.service -p NRestarts --value").strip()
    assert restarts == "0", f"ntfy-configure restarted {restarts}x"

    # The publisher token landed root-owned 0400 (non-root consumers read it via LoadCredential).
    machine.succeed("stat -c '%U:%G %a' /var/lib/homelab-secrets/notify-publishers/probe | grep -qx 'root:root 400'")

    # generateOnceGuard — first boot has no guarded data, so the secret is generated.
    machine.succeed("test -e /var/lib/homelab-secrets/test-guarded")

    # Data present + secret lost: leave it absent (a new value would orphan the data) and log why.
    machine.succeed("mkdir -p /var/lib/guard-data && touch /var/lib/guard-data/db")
    machine.succeed("rm /var/lib/homelab-secrets/test-guarded")
    machine.systemctl("restart homelab-runtime-secrets.service")
    machine.wait_for_unit("homelab-runtime-secrets.service")
    machine.fail("test -e /var/lib/homelab-secrets/test-guarded")
    machine.succeed("journalctl -u homelab-runtime-secrets.service | grep -q 'still holds data it protects'")

    # Data gone (empty guard): safe to regenerate.
    machine.succeed("rm -rf /var/lib/guard-data")
    machine.systemctl("restart homelab-runtime-secrets.service")
    machine.wait_for_unit("homelab-runtime-secrets.service")
    machine.succeed("test -e /var/lib/homelab-secrets/test-guarded")
  '';
}
