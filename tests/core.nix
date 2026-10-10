# Core smoke test: registry + runtime-secrets + the ntfy provider provision cleanly — the publisher token
# lands root-owned 0400 (non-root consumers read it via LoadCredential) — and a generate-once secret whose
# regeneration is gated on the presence of the data it protects (the generateOnce path).
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-core";

  nodes.machine = {
    imports = [ common ];

    selfhost = {
      notify.ntfy.enable = true;
      notify.topics.probes.public = false;
      notify.topics.alerts.public = false;
      notify.topics.announce.public = true;

      # A publisher that runs on another host: provisioned here, its token carried across by hand.
      notify.ntfy.remotePublishers.offsite.topic = "probes";

      # A non-human principal needing a Unix identity. Ids are pinned because they end up in the
      # ownership of files that can outlive the root filesystem.
      serviceAccounts.machine-probe = {
        description = "Probe SMB principal";
        unixAccount = {
          enable = true;
          uid = 977;
          gid = 977;
        };
      };

      # Guarded on a dir the test drives by hand, so the branches below are deterministic; the ordering
      # that makes a real service-owned guard safe is asserted separately.
      runtimeSecrets.test-guarded = {
        generateOnce = "/var/lib/guard-data";
      };

      # A task publisher (not a system user) — its token is still provisioned root-owned, no chown
      # gymnastics. Routing failures elsewhere makes it a two-grant publisher.
      tasks.probe = {
        systemdServices = [ "probe-dummy" ];
        integrations.notify = {
          enable = true;
          topic = "probes";
          failureTopic = "alerts";
        };
      };
    };

    systemd.services.probe-dummy.serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
    };

    # The ACL assertions below read the server's own view (CLI) and the provisioned flag (DB).
    environment.systemPackages = [
      pkgs.ntfy-sh
      pkgs.sqlite
    ];
  };

  testScript = ''
    # Runtime secret generated out-of-store with the declared mode.
    machine.wait_for_unit("homelab-runtime-secrets.service")
    machine.succeed("stat -c %a /var/lib/homelab-secrets/ntfy-admin-password | grep -qx 400")

    # The headline claim, checked directly: the generated value never lands in the world-readable store.
    secret = machine.succeed("cat /var/lib/homelab-secrets/ntfy-admin-password").strip()
    machine.fail(f"grep -rqF -- '{secret}' /nix/store")

    # ntfy provisions in one shot — no failed-then-restarted units.
    machine.wait_for_unit("ntfy-sh.service")
    machine.wait_for_unit("ntfy-provision.service")
    restarts = machine.succeed("systemctl show ntfy-provision.service -p NRestarts --value").strip()
    assert restarts == "0", f"ntfy-provision restarted {restarts}x"

    # The publisher token landed root-owned 0400 (non-root consumers read it via LoadCredential).
    machine.succeed("stat -c '%U:%G %a' /var/lib/homelab-secrets/notify-publishers/probe | grep -qx 'root:root 400'")

    # A remote publisher provisions identically.
    machine.succeed("stat -c '%U:%G %a' /var/lib/homelab-secrets/notify-publishers/offsite | grep -qx 'root:root 400'")

    # The auth env carries hashes and live tokens, so it must stay out of the store too.
    machine.succeed("stat -c '%U:%G %a' /var/lib/homelab-secrets/notify-auth.env | grep -qx 'root:root 400'")
    token = machine.succeed("cat /var/lib/homelab-secrets/notify-publishers/probe").strip()
    machine.fail(f"grep -rqF -- '{token}' /nix/store")

    # Declared publishers are provisioned rows, so the server owns them and ntfy-manage never grants.
    acl = machine.succeed("ntfy access")
    assert "write-only access to topic probes" in acl, acl
    # failureTopic is a second grant, not a replacement.
    assert "write-only access to topic alerts" in acl, acl
    # Public means anonymous read; private means no grant at all, which is what deny-all then denies.
    assert "read-only access to topic announce" in acl, acl
    assert "read-only access to topic probes" not in acl, acl

    provisioned = machine.succeed(
        "sqlite3 /var/lib/ntfy-sh/user.db 'select count(*) from user_access where provisioned = 1'"
    ).strip()
    assert provisioned != "0", "publisher grants are not provisioned rows; the reconcile would not own them"

    # Readers are runtime state: created against the live DB, with no deploy and no provisioned rows.
    added = machine.succeed("ntfy-manage reader add phone")
    assert "probes" in added and "alerts" in added, added
    assert "announce" not in added, "a public topic needs no grant"
    reader_acl = machine.succeed("ntfy access phone")
    assert "read-only access to topic probes" in reader_acl, reader_acl
    runtime_rows = machine.succeed(
        "sqlite3 /var/lib/ntfy-sh/user.db \"select count(*) from user_access ua join user u on ua.user_id = u.id where u.user = 'phone' and ua.provisioned = 1\""
    ).strip()
    assert runtime_rows == "0", "reader grants were provisioned; the next reconcile would delete them"

    # A reader survives the reconcile it shares a table with.
    machine.systemctl("restart ntfy-sh.service")
    machine.wait_for_unit("ntfy-sh.service")
    machine.succeed("ntfy access phone")

    # Nix owns these names; taking one would be silently overwritten by the next reconcile.
    machine.fail("ntfy-manage reader add probe")
    machine.fail("ntfy-manage reader add admin")
    machine.fail("ntfy-manage reader add phone")
    machine.fail("ntfy-manage reader remove probe")

    # Revocation is one command and takes the grants and tokens with it.
    machine.succeed("ntfy-manage reader remove phone")
    machine.fail("ntfy access phone")

    status = machine.succeed("ntfy-manage status")
    assert "announce" in status and "probe" in status, status

    # Flipping a topic private must revoke, not merely stop granting. Dropping the line the way a
    # rebuild would, then restarting the server, is the whole reconcile: provisioned rows are wiped and
    # rebuilt from config, so an omitted grant is gone.
    machine.succeed(
        "sed -i -e 's/,everyone:announce:ro//' -e 's/everyone:announce:ro,//' "
        "/var/lib/homelab-secrets/notify-auth.env"
    )
    machine.systemctl("restart ntfy-sh.service")
    machine.wait_for_unit("ntfy-sh.service")
    revoked = machine.succeed("ntfy access")
    assert "read-only access to topic announce" not in revoked, revoked

    # And the publisher grants came back from the same config, unduplicated.
    assert revoked.count("write-only access to topic probes") == 2, revoked

    # unixAccount.enable creates a system user with its own primary group, at the declared ids.
    machine.succeed("getent passwd machine-probe | cut -d: -f3,4 | grep -qx '977:977'")
    machine.succeed("getent group machine-probe | cut -d: -f3 | grep -qx 977")
    machine.succeed("test -s /var/lib/homelab-secrets/notify-publishers/offsite")

    # A guard is only safe because restartUnits orders its owning service after the generator, so the
    # service cannot populate the guarded path before the first generation is decided. ntfy's consumer is
    # the provisioner, which hashes the admin password; the server reaches it transitively through that.
    before = machine.succeed("systemctl show homelab-runtime-secrets.service -p Before --value")
    assert "ntfy-provision.service" in before, before
    provision_before = machine.succeed("systemctl show ntfy-provision.service -p Before --value")
    assert "ntfy-sh.service" in provision_before, provision_before

    # generateOnce — first boot has no guarded data, so the secret is generated.
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

    # The admin CLI groups by app and resolves a name to the same bytes as reading the path by hand.
    # Assertions read the captured output rather than piping into grep: the driver runs with pipefail,
    # and a `grep -q` closing the pipe early makes nushell exit non-zero.
    overview = machine.succeed("homelab-secrets ls")
    assert "ntfy" in overview, overview
    assert machine.succeed("homelab-secrets cat ntfy-admin-password") == machine.succeed(
        "cat /var/lib/homelab-secrets/ntfy-admin-password"
    ), "homelab-secrets cat diverged from the file"
    machine.fail("homelab-secrets cat no-such-secret")

    # Ownership drift is reported rather than tolerated, and the generator heals it on its next run.
    machine.succeed("chmod 0644 /var/lib/homelab-secrets/ntfy-admin-password")
    drifted = machine.succeed("homelab-secrets ls ntfy-admin-password")
    assert "drift" in drifted, drifted
    machine.systemctl("restart homelab-runtime-secrets.service")
    machine.wait_for_unit("homelab-runtime-secrets.service")
    healed = machine.succeed("homelab-secrets ls ntfy-admin-password")
    assert "ok" in healed, healed

    # A token under the 0700 publisher dir is unreadable to an unprivileged caller, not absent: calling
    # that "missing" would report a secret gone while it sits there.
    unpriv = "su -s /bin/sh nobody -c '/run/current-system/sw/bin/homelab-secrets"
    denied = machine.succeed(f"{unpriv} ls notify/probe'")
    assert "unknown" in denied and "missing" not in denied, denied
    machine.fail(f"{unpriv} cat notify/probe'")
  '';
}
