# Core smoke test: registry + runtime-secrets + the ntfy provider provision cleanly — including a
# publisher whose owner is not a system user (regression guard for review finding C1: the token
# chown must fall back to root rather than abort provisioning).
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-core";

  nodes.machine = {
    imports = [ common ];

    selfhost = {
      notify.ntfy.enable = true;
      notify.topics.probes.public = false;

      # owner = "probe" is not a system user — the case C1 mishandles.
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

    # ntfy provisions in one shot — no failed-then-restarted units, even for the userless publisher.
    machine.wait_for_unit("ntfy-sh.service")
    machine.wait_for_unit("ntfy-configure.service")
    restarts = machine.succeed("systemctl show ntfy-configure.service -p NRestarts --value").strip()
    assert restarts == "0", f"ntfy-configure restarted {restarts}x (likely the userless-publisher chown, C1)"

    # The publisher token landed with the intended mode.
    machine.succeed("stat -c %a /var/lib/homelab-secrets/notify-publishers/probe | grep -qx 400")
  '';
}
