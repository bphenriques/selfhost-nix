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

  # Resolve which systemd units a service needs for its storage mounts.
  # Priority: explicit storage.systemdServices > OCI container auto-detect > service name.
  ociContainers = config.virtualisation.oci-containers.containers or { };
  ociBackend = config.virtualisation.oci-containers.backend or "podman";

  resolveServiceUnits =
    svc:
    if svc.storage.systemdServices != [ ] then
      svc.storage.systemdServices
    else if ociContainers ? ${svc.name} then
      [ "${ociBackend}-${svc.name}" ]
    else
      [ svc.name ];

  servicesWithStorage = lib.filter (svc: svc.storage.mounts != [ ]) (lib.attrValues selfhostCfg.services);
  tasksWithStorage = lib.filter (task: task.storage.mounts != [ ]) (lib.attrValues selfhostCfg.tasks);

  serviceMountDeps = lib.foldl' (
    acc: svc:
    let
      units = resolveServiceUnits svc;
    in
    lib.foldl' (acc2: mountName: acc2 // { ${mountName} = (acc2.${mountName} or [ ]) ++ units; }) acc svc.storage.mounts
  ) { } servicesWithStorage;

  taskMountDeps = lib.foldl' (
    acc: task:
    lib.foldl' (
      acc2: mountName: acc2 // { ${mountName} = (acc2.${mountName} or [ ]) ++ task.systemdServices; }
    ) acc task.storage.mounts
  ) { } tasksWithStorage;

  allDependentUnits =
    mountName: mountCfg:
    lib.unique (
      mountCfg.systemd.dependentServices ++ (serviceMountDeps.${mountName} or [ ]) ++ (taskMountDeps.${mountName} or [ ])
    );

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

        allResolvedUnits =
          lib.concatMap resolveServiceUnits servicesWithStorage ++ lib.concatMap (task: task.systemdServices) tasksWithStorage;
        missingUnits = lib.filter (unit: !(config.systemd.services ? ${unit})) allResolvedUnits;

        tasksMissingUnits = lib.filter (task: task.storage.mounts != [ ] && task.systemdServices == [ ]) (
          lib.attrValues selfhostCfg.tasks
        );
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
        {
          assertion = missingUnits == [ ];
          message = "Storage mount wiring references unknown systemd units: ${lib.concatStringsSep ", " missingUnits}. Set storage.systemdServices explicitly if the unit name differs from the service name.";
        }
        {
          assertion = tasksMissingUnits == [ ];
          message = "Tasks with storage.mounts must declare systemdServices: ${
            lib.concatMapStringsSep ", " (t: t.name) tasksMissingUnits
          }";
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
