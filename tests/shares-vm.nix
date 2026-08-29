# storage.shares.smb (VM): a real smbd and a real CIFS mount. Covers what eval cannot — the passdb is
# provisioned from the credential files, the permissions unit lands setgid ownership on the share, and
# the resolved access list actually denies a write or a whole mount.
{ pkgs, common, ... }:
let
  adaPassword = "ada-secret";
  bobPassword = "bob-secret";
  backupPassword = "backup-secret";

  person = groups: passwordFile: {
    email = "person@test.local";
    firstName = "Test";
    lastName = "Person";
    inherit groups;
    auth.oidc.enable = false;
    storage.smb = {
      enable = true;
      inherit passwordFile;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "selfhost-shares";

  nodes.machine =
    { config, ... }:
    {
      imports = [ common ];

      environment.systemPackages = [
        pkgs.cifs-utils
        config.services.samba.package
      ];

      # Stands in for the backing store: on a real host this path is a dataset the host mounted.
      systemd.tmpfiles.rules = [ "d /srv/storage 0700 root root -" ];

      users.users.ada = {
        isNormalUser = true;
        uid = 4000;
      };
      users.users.bob = {
        isNormalUser = true;
        uid = 4001;
      };
      # smbpasswd -a needs a Unix account; this one is never declared as a principal.
      users.users.stale = {
        isSystemUser = true;
        group = "nogroup";
      };

      environment.etc = {
        "smb/ada".text = adaPassword;
        "smb/bob".text = bobPassword;
        "smb/machine-backup".text = backupPassword;
      };

      selfhost = {
        users.ada = person [ "family" ] "/etc/smb/ada";
        users.bob = person [ "family" ] "/etc/smb/bob";

        serviceAccounts.machine-backup = {
          description = "Backup principal";
          systemUser = {
            enable = true;
            uid = 977;
            gid = 977;
          };
          storage.smb = {
            enable = true;
            passwordFile = "/etc/smb/machine-backup";
          };
        };

        storage.shares.smb = {
          enable = true;
          shares = {
            media = {
              path = "/srv/storage/media";
              owner = "ada";
              gid = 990;
              directories = [ "movies" ];
              access = {
                groups.family = "rw";
                users.machine-backup = "ro";
              };
            };
            photos = {
              path = "/srv/storage/photos";
              owner = "ada";
              gid = 991;
              access = {
                groups.family = "rw";
                users.bob = "ro";
              };
            };
            vault = {
              path = "/srv/storage/vault";
              owner = "ada";
              gid = 992;
              access = {
                groups.family = "rw";
                users.bob = "none";
              };
            };
          };
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("samba-smbd.service")
    machine.wait_for_open_port(445)

    with subtest("permissions unit prepares the share"):
        # The parent must stay traversable even though tmpfiles asked for 0700: smbd drops to the
        # connecting user, so a private parent would deny every session.
        assert machine.succeed("stat -c %a /srv/storage").strip() == "755"
        assert machine.succeed("stat -c %a:%U:%G /srv/storage/media").strip() == "2770:ada:storage-media"
        assert machine.succeed("stat -c %a:%U:%G /srv/storage/media/movies").strip() == "2770:ada:storage-media"

    with subtest("both registries are provisioned into the passdb"):
        accounts = machine.succeed("pdbedit -L")
        assert "ada" in accounts, accounts
        assert "machine-backup" in accounts, accounts

    with subtest("an undeclared account is revoked, not left behind"):
        machine.succeed("printf 'x\\nx\\n' | smbpasswd -a -s stale")
        assert "stale" in machine.succeed("pdbedit -L")
        machine.succeed("systemctl restart selfhost-smb-passwords.service")
        assert "stale" not in machine.succeed("pdbedit -L")

    with subtest("an anonymous session is refused"):
        machine.fail("smbclient -N -L //localhost 2>&1")

    with subtest("the dialect floor is SMB 3.1.1"):
        # `server min protocol = SMB3` is an alias for SMB3_11, not SMB3_00, so older SMB3 is refused.
        machine.succeed("mkdir -p /mnt/rw")
        machine.fail(
            "mount -t cifs //localhost/media /mnt/rw"
            " -o username=ada,password=${adaPassword},vers=3.0"
        )

    with subtest("a granted principal writes"):
        machine.succeed(
            "mount -t cifs //localhost/media /mnt/rw"
            " -o username=ada,password=${adaPassword},vers=3.1.1"
        )
        machine.succeed("touch /mnt/rw/movies/hello")
        # force group + create mask, so the share's group owns what lands in it.
        assert machine.succeed("stat -c %G /srv/storage/media/movies/hello").strip() == "storage-media"
        machine.succeed("umount /mnt/rw")

    with subtest("a read-only principal reads but cannot write"):
        machine.succeed("mkdir -p /mnt/ro")
        machine.succeed(
            "mount -t cifs //localhost/media /mnt/ro"
            " -o username=machine-backup,password=${backupPassword},vers=3.1.1"
        )
        machine.succeed("test -f /mnt/ro/movies/hello")
        machine.fail("touch /mnt/ro/denied")
        machine.succeed("umount /mnt/ro")

    with subtest("a principal admitted only by a group grant writes"):
        # bob holds no `users` entry on media; `groups.family = "rw"` is his whole claim to it.
        assert "bob" in machine.succeed("getent group storage-media")
        machine.succeed(
            "mount -t cifs //localhost/media /mnt/rw"
            " -o username=bob,password=${bobPassword},vers=3.1.1"
        )
        machine.succeed("touch /mnt/rw/movies/from-bob")
        machine.succeed("umount /mnt/rw")

    with subtest("a user grant downgrades the group grant"):
        machine.succeed(
            "mount -t cifs //localhost/photos /mnt/ro"
            " -o username=bob,password=${bobPassword},vers=3.1.1"
        )
        machine.fail("touch /mnt/ro/denied")
        machine.succeed("umount /mnt/ro")
        # ada, same group, no `users` entry, keeps the rw the group gave.
        machine.succeed(
            "mount -t cifs //localhost/photos /mnt/rw"
            " -o username=ada,password=${adaPassword},vers=3.1.1"
        )
        machine.succeed("touch /mnt/rw/from-ada")
        machine.succeed("umount /mnt/rw")

    with subtest("a `none` user grant revokes the group grant"):
        assert "bob" not in machine.succeed("getent group storage-vault")
        machine.fail(
            "mount -t cifs //localhost/vault /mnt/ro"
            " -o username=bob,password=${bobPassword},vers=3.1.1"
        )
        machine.succeed(
            "mount -t cifs //localhost/vault /mnt/rw"
            " -o username=ada,password=${adaPassword},vers=3.1.1"
        )
        machine.succeed("umount /mnt/rw")
  '';
}
