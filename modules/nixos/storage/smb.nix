{
  lib,
  config,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.selfhost.storage.mounts.smb;
  selfhostCfg = config.selfhost;

  mountUnit = mountCfg: "${utils.escapeSystemdPath mountCfg.localMount}.mount";
  automountUnit = mountCfg: "${utils.escapeSystemdPath mountCfg.localMount}.automount";

  # Services and tasks are the same shape here: both name the units they own, and both want their
  # shares' automount guards started first.
  entriesWithStorage = lib.filter (e: e.storage.mounts != [ ]) (
    lib.attrValues selfhostCfg.services ++ lib.attrValues selfhostCfg.tasks
  );

  mountDeps = lib.foldl' (
    acc: entry:
    lib.foldl' (
      acc2: mountName: acc2 // { ${mountName} = (acc2.${mountName} or [ ]) ++ entry.systemdServices; }
    ) acc entry.storage.mounts
  ) { } entriesWithStorage;

  allDependentUnits =
    mountName: mountCfg: lib.unique (mountCfg.systemd.dependentServices ++ (mountDeps.${mountName} or [ ]));

  smbMountCfg = lib.types.submodule (
    { name, config, ... }: {
      options = {
        localMount = lib.mkOption {
          type = lib.types.str;
          default = "/mnt/homelab-${name}";
          description = "Local mount point for the share";
        };
        group = lib.mkOption {
          type = lib.types.str;
          default = "homelab-${name}";
          description = "Name of the group with access to the mount";
        };
        uid = lib.mkOption {
          type = lib.types.int;
          default = 0;
          description = "File-owner UID on the client (default 0/root → access via group; set per-user for owner-level ops like chmod/git).";
        };
        gid = lib.mkOption {
          type = lib.types.int;
          description = "GID for the mount group (required for SMB mount options)";
        };
        systemd.dependentServices = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra systemd service names to order after this share's automount guard.";
        };
      };
    }
  );
in
{
  options.selfhost.storage.mounts.smb = {
    enable = lib.mkEnableOption "Home-server storage";

    hostname = lib.mkOption {
      type = lib.types.str;
      description = "IP or hostname of the SMB server; prefer an IP or /etc/hosts entry for reliable resolution at boot.";
    };

    credentialsPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to the SMB credentials file (must be provided by the host, e.g. via sops-nix)";
    };

    shares = lib.mkOption {
      type = lib.types.attrsOf smbMountCfg;
      default = { };
      description = ''
        CIFS shares keyed by remote root folder, each behind a dedicated access group and mounted on
        demand. Boot does not wait for the SMB server. First access may wait up to 30 seconds; after a
        failed mount, a later access retries.
      '';
      example = lib.literalExpression ''
        {
          bphenriques = { };
          media = { };
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    assertions =
      let
        allGids = lib.mapAttrsToList (_: m: m.gid) cfg.shares;
        dupGids = lib.filter (gid: lib.count (g: g == gid) allGids > 1) (lib.unique allGids);
        allLocalMounts = lib.mapAttrsToList (_: m: m.localMount) cfg.shares;
        dupLocalMounts = lib.filter (path: lib.count (p: p == path) allLocalMounts > 1) (lib.unique allLocalMounts);
      in
      [
        {
          assertion = dupGids == [ ];
          message = "Homelab mounts have duplicate gids: ${toString dupGids}";
        }
        {
          assertion = dupLocalMounts == [ ];
          message = "Homelab mounts have duplicate local paths: ${lib.concatStringsSep ", " dupLocalMounts}";
        }
        {
          assertion = !lib.elem "/" allLocalMounts;
          message = "Homelab mounts cannot use / as a local path";
        }
      ];

    environment.systemPackages = [ pkgs.cifs-utils ];

    users.groups = lib.mapAttrs' (_name: mountCfg: lib.nameValuePair mountCfg.group { inherit (mountCfg) gid; }) cfg.shares;

    fileSystems = lib.mapAttrs' (
      name: mountCfg:
      lib.nameValuePair mountCfg.localMount {
        device = "//${cfg.hostname}/${name}";
        fsType = "cifs";
        options = [
          # Permissions
          "uid=${toString mountCfg.uid}"
          "gid=${toString mountCfg.gid}"
          "file_mode=0660"
          "dir_mode=0770"

          # Security: nosuid/nodev/noexec; vers=default negotiates the highest SMB2+ dialect (>=2.1, never SMB1)
          "nosuid"
          "nodev"
          "noexec"
          "vers=default"

          "credentials=${cfg.credentialsPath}"

          "_netdev"
          "nofail"
          "x-systemd.automount"
          "x-systemd.mount-timeout=30s"
        ];
      }
    ) cfg.shares;

    systemd.units = lib.mapAttrs' (
      _name: mountCfg:
      lib.nameValuePair (mountUnit mountCfg) {
        overrideStrategy = "asDropin";
        text = ''
          [Unit]
          StartLimitIntervalSec=0
        '';
      }
    ) cfg.shares;

    # node_exporter reports a hung mount as device_error="mountpoint timeout" (needs its filesystem
    # collector). The automount retries on its own, so `for` outlasts a NAS reboot: this fires only
    # once a share has failed to come back, not on every blip.
    selfhost.monitoring.scopes.smb-storage.rules = [
      {
        name = "smb-storage";
        rules = [
          {
            alert = "StorageMountUnavailable";
            expr = ''node_filesystem_device_error{fstype="cifs"} == 1'';
            "for" = "10m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.mountpoint }} not responding";
          }
        ];
      }
    ];

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (
        name: mountCfg:
        let
          automount = automountUnit mountCfg;
        in
        lib.listToAttrs (
          map (svcName: {
            name = svcName;
            value = {
              requires = [ automount ];
              after = [ automount ];
            };
          }) (allDependentUnits name mountCfg)
        )
      ) cfg.shares
    );
  };
}
