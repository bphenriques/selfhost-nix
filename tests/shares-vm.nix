# storage.shares.smb (VM): a real smbd and a real CIFS mount. Covers what eval cannot: the passdb is
# provisioned from the credential files, the resolved access list actually denies a write or a whole
# mount, and a second door into one tree stays confined to its subdirectory. Ownership is the host's, so
# the node sets it up the way a consumer would.
{ pkgs, common, ... }:
let
  inherit (pkgs) lib;

  adaPassword = "ada-secret";
  bobPassword = "bob-secret";
  backupPassword = "backup-secret";
  agentPassword = "agent-secret";

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

  machine = uid: passwordFile: {
    unixAccount = {
      enable = true;
      inherit uid;
      gid = uid;
    };
    storage.smb = {
      enable = true;
      inherit passwordFile;
    };
  };

  # The host's side: one group per tree, setgid roots, and samba forcing that group on every door into it.
  trees = {
    media = {
      gid = 990;
      doors = [
        "media"
        "movies"
      ];
    };
    photos = {
      gid = 991;
      doors = [ "photos" ];
    };
    vault = {
      gid = 992;
      doors = [ "vault" ];
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "selfhost-shares";

  nodes.machine =
    { config, ... }:
    let
      shares = config.selfhost.storage.shares.smb.shares;
    in
    {
      imports = [ common ];

      environment.systemPackages = [
        pkgs.cifs-utils
        config.services.samba.package
      ];

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

      users.groups = lib.mapAttrs' (
        tree: t:
        lib.nameValuePair "storage-${tree}" {
          inherit (t) gid;
          members = lib.unique (lib.concatMap (door: lib.attrNames shares.${door}.resolvedAccess) t.doors);
        }
      ) trees;

      systemd.tmpfiles.rules = [
        "d /srv/storage 0755 root root -"
        "d /srv/storage/media/movies 2770 ada storage-media -"
        "d /srv/storage/media/private 2770 ada storage-media -"
      ]
      ++ map (tree: "d /srv/storage/${tree} 2770 ada storage-${tree} -") (lib.attrNames trees);

      services.samba.settings = lib.concatMapAttrs (
        tree: t:
        lib.genAttrs t.doors (_: {
          "force group" = "storage-${tree}";
          "create mask" = "0660";
          "directory mask" = "2770";
          "force create mode" = "0660";
          "force directory mode" = "2770";
        })
      ) trees;

      environment.etc = {
        "smb/ada".text = adaPassword;
        "smb/bob".text = bobPassword;
        "smb/machine-backup".text = backupPassword;
        "smb/machine-agent".text = agentPassword;
      };

      selfhost = {
        users.ada = person [ "family" ] "/etc/smb/ada";
        users.bob = person [ "family" ] "/etc/smb/bob";

        serviceAccounts.machine-backup = machine 977 "/etc/smb/machine-backup";
        serviceAccounts.machine-agent = machine 976 "/etc/smb/machine-agent";

        storage.shares.smb = {
          enable = true;
          shares = {
            media = {
              path = "/srv/storage/media";
              access = {
                groups.family = "rw";
                serviceAccounts.machine-backup = "ro";
              };
            };
            # A second door into the media tree, for a principal that must see nothing else of it.
            movies = {
              path = "/srv/storage/media/movies";
              access.serviceAccounts.machine-agent = "rw";
            };
            photos = {
              path = "/srv/storage/photos";
              access = {
                groups.family = "rw";
                users.bob = "ro";
              };
            };
            vault = {
              path = "/srv/storage/vault";
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

    def mount(share, user, password, at):
        machine.succeed(f"mkdir -p {at}")
        machine.succeed(f"mount -t cifs //localhost/{share} {at} -o username={user},password={password},vers=3.1.1")

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
        mount("media", "ada", "${adaPassword}", "/mnt/rw")
        machine.succeed("touch /mnt/rw/movies/hello /mnt/rw/private/secret")
        assert machine.succeed("stat -c %G /srv/storage/media/movies/hello").strip() == "storage-media"
        machine.succeed("umount /mnt/rw")

    with subtest("a read-only principal reads but cannot write"):
        mount("media", "machine-backup", "${backupPassword}", "/mnt/ro")
        machine.succeed("test -f /mnt/ro/movies/hello")
        machine.fail("touch /mnt/ro/denied")
        machine.succeed("umount /mnt/ro")

    with subtest("a principal admitted only by a group grant writes"):
        # bob holds no `users` entry on media; `groups.family = "rw"` is his whole claim to it.
        assert "bob" in machine.succeed("getent group storage-media")
        mount("media", "bob", "${bobPassword}", "/mnt/rw")
        machine.succeed("touch /mnt/rw/movies/from-bob")
        machine.succeed("umount /mnt/rw")

    with subtest("a second door into one tree shares its files both ways"):
        mount("movies", "machine-agent", "${agentPassword}", "/mnt/agent")
        machine.succeed("test -f /mnt/agent/hello")
        machine.succeed("touch /mnt/agent/from-agent")
        machine.succeed("umount /mnt/agent")
        assert machine.succeed("stat -c %G /srv/storage/media/movies/from-agent").strip() == "storage-media"
        mount("media", "ada", "${adaPassword}", "/mnt/rw")
        machine.succeed("echo edit >> /mnt/rw/movies/from-agent")
        machine.succeed("umount /mnt/rw")

    with subtest("the second door confines its principal to the subdirectory"):
        machine.fail(
            "mount -t cifs //localhost/media /mnt/agent"
            " -o username=machine-agent,password=${agentPassword},vers=3.1.1"
        )
        # Samba refuses to follow a link out of the share unless `wide links` is set. The link that
        # stays inside proves the refusal is samba's, not a client that follows no links at all.
        machine.succeed("ln -s /srv/storage/media/private /srv/storage/media/movies/escape")
        machine.succeed("ln -s /srv/storage/media/movies/hello /srv/storage/media/movies/inside")
        mount("movies", "machine-agent", "${agentPassword}", "/mnt/agent")
        machine.succeed("test -f /mnt/agent/inside")
        machine.fail("ls /mnt/agent/escape/secret")
        machine.succeed("umount /mnt/agent")

    with subtest("a user grant downgrades the group grant"):
        mount("photos", "bob", "${bobPassword}", "/mnt/ro")
        machine.fail("touch /mnt/ro/denied")
        machine.succeed("umount /mnt/ro")
        # ada, same group, no `users` entry, keeps the rw the group gave.
        mount("photos", "ada", "${adaPassword}", "/mnt/rw")
        machine.succeed("touch /mnt/rw/from-ada")
        machine.succeed("umount /mnt/rw")

    with subtest("a `none` user grant revokes the group grant"):
        assert "bob" not in machine.succeed("getent group storage-vault")
        machine.fail(
            "mount -t cifs //localhost/vault /mnt/ro"
            " -o username=bob,password=${bobPassword},vers=3.1.1"
        )
        mount("vault", "ada", "${adaPassword}", "/mnt/rw")
        machine.succeed("umount /mnt/rw")
  '';
}
