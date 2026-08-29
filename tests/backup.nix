# Backup: a target assembles a standalone hook's output and a read-only binding, and rustic snapshots the
# tree into a local repo. Starting the oneshot exercises the whole pipeline (assemble → init → backup →
# prune → check). notify is enabled so the per-publisher token env resolves; nothing is actually sent.
#
# Two targets share one repository and a foreign host's snapshots are seeded into it, so the same run
# also covers the scoping that keeps one pipeline's retention off another's snapshots.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-backup";

  nodes.machine =
    { pkgs, ... }:
    let
      # Test fixture only: a repo under the service's already-writable stateDir, so the pipeline runs without a
      # remote backend. Real repos are remote or on a mounted disk — a local repo on the root fs is pointless.
      repository = "/var/lib/homelab-backup/repo";
      passwordFile = builtins.toFile "rustic-pw" "test-password";
      retention = {
        daily = "7 days";
        weekly = "1 month";
        monthly = "1 year";
        yearly = "2 years";
      };
    in
    {
      imports = [ common ];

      # Seeding foreign snapshots into the shared repo needs rustic outside the service.
      environment.systemPackages = [ pkgs.rustic ];

      # Source trees to bind read-only into the snapshots.
      systemd.tmpfiles.rules = [
        "d /srv/data 0755 root root -"
        "f /srv/data/file.txt 0644 root root - bound-content"
        "d /srv/other 0755 root root -"
        "f /srv/other/file.txt 0644 root root - other-content"
      ];

      selfhost = {
        notify.ntfy.enable = true;

        backup = {
          package = pkgs.selfhost.rustic-manage;
          targets = {
            test = {
              inherit repository passwordFile retention;
              bindings."/data" = "/srv/data";
              hooks.greet.package = pkgs.writeShellApplication {
                name = "greet-hook";
                text = ''echo "hook-output" > "$OUTPUT_DIR/greeting.txt"'';
              };
            };
            # A second pipeline in the same repository: neither target may age the other's snapshots.
            other = {
              inherit repository passwordFile retention;
              bindings."/data" = "/srv/other";
            };
            # Configured but switched off: keeps its settings, contributes no units.
            paused = {
              enable = false;
              inherit repository passwordFile retention;
              bindings."/data" = "/srv/other";
            };
          };
        };
      };
    };

  testScript = ''
    import json

    REPO = "/var/lib/homelab-backup/repo"
    R = f"rustic -r {REPO} --password test-password"

    def snapshots():
        groups = json.loads(machine.succeed(f"{R} snapshots --json"))
        return [s for g in groups for s in g["snapshots"]]

    # The seeds are identified by their backdated timestamps rather than by id, because re-tagging a
    # snapshot rewrites it under a new id.
    def seed(day):
        return [s for s in snapshots() if s["time"].startswith(f"2020-01-0{day}")]

    machine.wait_for_unit("multi-user.target")

    # The oneshot blocks until the whole pipeline finishes; a non-zero exit fails the test.
    machine.succeed("systemctl start homelab-backup-test.service")
    machine.succeed("systemctl start homelab-backup-other.service")

    # The repo was initialized and holds a snapshot.
    machine.succeed(f"test -f {REPO}/config")
    machine.succeed(f"test -n \"$(ls -A {REPO}/snapshots)\"")

    # A disabled target contributes neither a service nor a timer.
    machine.fail("systemctl cat homelab-backup-paused.service")
    machine.fail("systemctl cat homelab-backup-paused.timer")

    live = snapshots()
    assert any("target:test" in s["tags"] for s in live), "test target wrote no scope tag"
    assert any("target:other" in s["tags"] for s in live), "other target wrote no scope tag"

    # Seed snapshots that `test`'s retention would drop if they were in its scope. Each backdated seed
    # needs a same-group companion at the current time, because keep-within is measured from the newest
    # snapshot in the group: a lone old snapshot is kept no matter how old it is.
    machine.succeed(f"{R} backup --host otherhost --tag target:test --time '2020-01-01 00:00:00' /srv/data")
    machine.succeed(f"{R} backup --host otherhost --tag target:test /srv/data")
    machine.succeed(f"{R} backup --tag target:other --time '2020-01-02 00:00:00' /srv/data")
    machine.succeed(f"{R} backup --tag target:test --time '2020-01-03 00:00:00' /srv/data")
    machine.succeed(f"{R} backup --tag target:test --time '2020-01-04 00:00:00' /srv/data")
    machine.succeed(f"{R} backup --tag target:test /srv/data")

    machine.succeed(f"{R} tag --add keep-forever {seed(3)[0]['id']}")

    machine.succeed("systemctl start homelab-backup-test.service")

    # Control: an in-scope seed older than every keep-within window must be gone, or the survivals below
    # would pass against a forget that does nothing at all.
    assert seed(4) == [], "retention removed nothing in scope; the assertions below prove nothing"

    assert seed(1), "a co-tenant host's snapshot was removed by this host's retention"
    assert seed(2), "another target's snapshot was removed by this target's retention"
    assert seed(3), "a keep-forever snapshot was removed"
    assert "keep-forever" in seed(3)[0]["tags"]

    # An untagged snapshot matches no scope, so nothing would ever forget it.
    unscoped = [s["id"] for s in snapshots() if not any(t.startswith("target:") for t in s["tags"])]
    assert unscoped == [], f"snapshots outside every scope: {unscoped}"

    # Pruning against one scope must leave every other scope's data readable.
    machine.succeed(f"{R} check --read-data")
    machine.succeed(f"{R} restore {seed(1)[0]['id']} /tmp/restored")
    machine.succeed("find /tmp/restored -name file.txt -exec grep -q bound-content {} +")

    # The second run must reuse the first as parent; a snapshot-filter that also narrowed the parent
    # search would hide it and re-read the whole tree every night.
    summary = machine.succeed("cat /var/lib/homelab-backup/test-last-summary.txt")
    assert "0 new" in summary, f"backup found no parent: {summary}"
  '';
}
