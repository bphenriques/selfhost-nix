{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.selfhost.storage.smb;
  selfhostCfg = config.selfhost;

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

  servicesWithStorage = lib.filter (svc: svc.storage.smb != [ ]) (lib.attrValues selfhostCfg.services);
  tasksWithStorage = lib.filter (task: task.storage.smb != [ ]) (lib.attrValues selfhostCfg.tasks);

  serviceMountDeps = lib.foldl' (
    acc: svc:
    let
      units = resolveServiceUnits svc;
    in
    lib.foldl' (acc2: mountName: acc2 // { ${mountName} = (acc2.${mountName} or [ ]) ++ units; }) acc svc.storage.smb
  ) { } servicesWithStorage;

  taskMountDeps = lib.foldl' (
    acc: task:
    lib.foldl' (
      acc2: mountName: acc2 // { ${mountName} = (acc2.${mountName} or [ ]) ++ task.systemdServices; }
    ) acc task.storage.smb
  ) { } tasksWithStorage;

  allDependentUnits =
    mountName: mountCfg:
    lib.unique (
      mountCfg.systemd.dependentServices ++ (serviceMountDeps.${mountName} or [ ]) ++ (taskMountDeps.${mountName} or [ ])
    );

  hasDepServices = mountName: mountCfg: allDependentUnits mountName mountCfg != [ ];

  smbMountCfg = lib.types.submodule (
    { name, config, ... }: {
      options = {
        localMount = lib.mkOption {
          type = lib.types.str;
          default = "/mnt/homelab-${name}";
          description = "Local mount point for the share";
        };
        remote = lib.mkOption {
          type = lib.types.str;
          default = name;
          readOnly = true;
          description = "Remote folder name on the selfhost server";
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
          description = "Extra units needing this mount, for non-registry/dynamic cases (registry services should use storage.smb).";
        };
      };
    }
  );
in
{
  options.selfhost.storage.smb = {
    enable = lib.mkEnableOption "Home-server storage";

    hostname = lib.mkOption {
      type = lib.types.str;
      description = "IP or hostname of the SMB server; prefer an IP or /etc/hosts entry for reliable resolution at boot.";
    };

    credentialsPath = lib.mkOption {
      type = lib.types.str;
      description = "Path to the SMB credentials file (must be provided by the host, e.g. via sops-nix)";
    };

    mounts = lib.mkOption {
      type = lib.types.attrsOf smbMountCfg;
      default = { };
      description = ''
        CIFS shares keyed by remote root folder, each behind a dedicated access group. Mount mode is
        chosen per share: one with dependents boot-mounts with `nofail` (services retry), while an
        independent share uses lazy `x-systemd.automount` on first access — dodging the boot-time network
        race that ordering a service after the mount (`RequiresMountsFor`) would otherwise hit.
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
        allGids = lib.mapAttrsToList (_: m: m.gid) cfg.mounts;
        dupGids = lib.filter (gid: lib.count (g: g == gid) allGids > 1) (lib.unique allGids);

        allResolvedUnits =
          lib.concatMap resolveServiceUnits servicesWithStorage ++ lib.concatMap (task: task.systemdServices) tasksWithStorage;
        missingUnits = lib.filter (unit: !(config.systemd.services ? ${unit})) allResolvedUnits;

        tasksMissingUnits = lib.filter (task: task.storage.smb != [ ] && task.systemdServices == [ ]) (
          lib.attrValues selfhostCfg.tasks
        );
      in
      [
        {
          assertion = dupGids == [ ];
          message = "Homelab mounts have duplicate gids: ${toString dupGids}";
        }
        {
          assertion = missingUnits == [ ];
          message = "Storage mount wiring references unknown systemd units: ${lib.concatStringsSep ", " missingUnits}. Set storage.systemdServices explicitly if the unit name differs from the service name.";
        }
        {
          assertion = tasksMissingUnits == [ ];
          message = "Tasks with storage.smb must declare systemdServices: ${
            lib.concatMapStringsSep ", " (t: t.name) tasksMissingUnits
          }";
        }
      ];

    environment.systemPackages = [ pkgs.cifs-utils ];

    users.groups = lib.mapAttrs' (_name: mountCfg: lib.nameValuePair mountCfg.group { inherit (mountCfg) gid; }) cfg.mounts;

    fileSystems = lib.mapAttrs' (
      name: mountCfg:
      lib.nameValuePair mountCfg.localMount {
        device = "//${cfg.hostname}/${mountCfg.remote}";
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
        ]
        # Dependent mounts boot-mount with nofail (RequiresMountsFor can't coexist with lazy automount);
        # independent mounts automount on first access, dodging the boot network race.
        ++ (
          if hasDepServices name mountCfg then
            [
              "nofail"
              "x-systemd.mount-timeout=30s"
            ]
          else
            [
              "noauto"
              "x-systemd.automount"
              "x-systemd.mount-timeout=30s"
            ]
        );
      }
    ) cfg.mounts;

    systemd.services = lib.mkMerge (
      lib.mapAttrsToList (
        name: mountCfg:
        lib.listToAttrs (
          map (svcName: {
            name = svcName;
            value = {
              unitConfig.RequiresMountsFor = [ mountCfg.localMount ];

              # Retry with delays if mount isn't ready yet (network filesystem race at boot)
              serviceConfig = {
                Restart = lib.mkDefault "on-failure";
                RestartSec = lib.mkDefault "10s";
              };
              startLimitIntervalSec = lib.mkDefault 180; # 3 minutes
              startLimitBurst = lib.mkDefault 10;
            };
          }) (allDependentUnits name mountCfg)
        )
      ) cfg.mounts
    );
  };
}
