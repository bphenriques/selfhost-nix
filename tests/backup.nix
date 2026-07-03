# Backup: a target assembles a standalone hook's output and a read-only binding, and rustic snapshots the
# tree into a local repo. Starting the oneshot exercises the whole pipeline (assemble → init → backup →
# prune → check). notify is enabled so the per-publisher token env resolves; nothing is actually sent.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-backup";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ common ];

      # A source tree to bind read-only into the snapshot.
      systemd.tmpfiles.rules = [
        "d /srv/data 0755 root root -"
        "f /srv/data/file.txt 0644 root root - bound-content"
      ];

      selfhost = {
        notify.ntfy.enable = true;

        backup = {
          package = pkgs.selfhost.rustic-manage;
          targets.test = {
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
            bindings."/data" = "/srv/data";
            hooks.greet.package = pkgs.writeShellApplication {
              name = "greet-hook";
              text = ''echo "hook-output" > "$OUTPUT_DIR/greeting.txt"'';
            };
          };
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    # The oneshot blocks until the whole pipeline finishes; a non-zero exit fails the test.
    machine.succeed("systemctl start homelab-backup-test.service")

    # The repo was initialized and holds a snapshot.
    machine.succeed("test -f /var/lib/homelab-backup/repo/config")
    machine.succeed("test -n \"$(ls -A /var/lib/homelab-backup/repo/snapshots)\"")
  '';
}
