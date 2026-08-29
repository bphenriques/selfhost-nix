# SMB file server, the counterpart to `storage.mounts.smb` on the client. The backing store stays the
# host's: `path` points at what it already mounted, and this only exports it and fixes ownership.
# Anything samba already exposes stays samba's: add `services.samba.settings.<share>` keys alongside.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  selfhostCfg = config.selfhost;
  cfg = selfhostCfg.storage.shares.smb;
  selfhostLib = import ../lib.nix { inherit lib; };

  # To smbd a person and a machine are the same: a name, a password, a Unix identity.
  principals = lib.filterAttrs (_: p: p.storage.smb.enable) (selfhostCfg.users // selfhostCfg.serviceAccounts);

  knownGroups = selfhostLib.knownGroups selfhostCfg;

  levelRank = {
    ro = 1;
    rw = 2;
  };

  # Only people hold groups, so a service account always resolves through `access.users`.
  groupLevel =
    share: name:
    let
      granted = lib.filter (level: level != null) (
        map (group: share.access.groups.${group} or null) (selfhostCfg.users.${name}.groups or [ ])
      );
    in
    if granted == [ ] then "none" else lib.head (lib.sort (a: b: levelRank.${a} > levelRank.${b}) granted);

  # A `users` grant replaces whatever the groups produced for that principal, `none` included.
  resolved = lib.mapAttrs (
    _: share:
    lib.filterAttrs (_: level: level != "none") (
      lib.mapAttrs (name: _: share.access.users.${name} or (groupLevel share name)) principals
    )
  ) cfg.shares;

  userGrantees = lib.unique (lib.concatMap (s: lib.attrNames s.access.users) (lib.attrValues cfg.shares));
  grantedGroups = lib.unique (lib.concatMap (s: lib.attrNames s.access.groups) (lib.attrValues cfg.shares));

  # smbd drops to the connecting user, so the parent of every share root must stay traversable.
  shareParents = lib.unique (lib.filter (p: p != "/") (map (s: dirOf s.path) (lib.attrValues cfg.shares)));

  # Plain directories are created; mounted ones only have their ownership fixed, hence the mount guards.
  ownedPaths = share: [ share.path ] ++ map (dir: "${share.path}/${dir}") share.directories;
  allOwnedPaths = lib.concatMap ownedPaths (lib.attrValues cfg.shares);

  mkShare =
    name: share:
    let
      access = resolved.${name};
      readOnly = lib.attrNames (lib.filterAttrs (_: level: level == "ro") access);
    in
    lib.optionalAttrs (readOnly != [ ]) { "read list" = lib.concatStringsSep " " readOnly; }
    // {
      inherit (share) path;
      browseable = "yes";
      "read only" = "no";
      "valid users" = lib.concatStringsSep " " (lib.attrNames access);
      "force group" = share.group;
      "create mask" = "0660";
      "directory mask" = "2770";
      "force create mode" = "0660";
      "force directory mode" = "2770";
    };

  setPermissions = pkgs.writeShellApplication {
    name = "selfhost-smb-permissions";
    runtimeInputs = [ pkgs.coreutils ];
    text =
      lib.concatMapStringsSep "\n" (
        parent:
        lib.escapeShellArgs [
          "install"
          "-d"
          "-m"
          "00755"
          "-o"
          "root"
          "-g"
          "root"
          parent
        ]
      ) shareParents
      + "\n"
      + lib.concatMapStringsSep "\n" (
        share:
        lib.escapeShellArgs (
          [
            "install"
            "-d"
            "-m"
            "2770"
            "-o"
            share.owner
            "-g"
            share.group
          ]
          ++ ownedPaths share
        )
      ) (lib.attrValues cfg.shares);
  };

  provisionPasswords = pkgs.writeShellApplication {
    name = "selfhost-smb-passwords";
    runtimeInputs = [
      pkgs.coreutils
      config.services.samba.package
    ];
    text = builtins.readFile ./samba-passwords.sh;
  };
in
{
  options.selfhost.storage.shares.smb = {
    enable = lib.mkEnableOption "an SMB server exporting the shares declared here";

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open TCP 445. Only 445: netbios is disabled, so 137-139 never listen.";
    };

    shares = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                example = "/srv/storage/media";
                description = "Absolute path exported under this share name. The host prepares and mounts it; this module never creates the backing store.";
              };

              owner = lib.mkOption {
                type = lib.types.str;
                default = "root";
                description = "Unix owner of the share root. Independent of `access`: a share may be owned by a principal holding no grant on it, as when its data is reached through an application rather than over SMB.";
              };

              group = lib.mkOption {
                type = lib.types.str;
                default = "storage-${name}";
                defaultText = lib.literalMD "`storage-<name>`";
                description = "Group owning the share, forced onto everything written into it. Its members are whoever `access` resolves to.";
              };

              gid = lib.mkOption {
                type = lib.types.nullOr lib.types.int;
                default = null;
                description = "As in `users.groups.<name>.gid`. Null picks a free one on activation; pin it, since the share data outlives the root filesystem that recorded the allocation.";
              };

              access = lib.mkOption {
                type = lib.types.submodule {
                  options = {
                    groups = lib.mkOption {
                      type = lib.types.attrsOf (
                        lib.types.enum [
                          "rw"
                          "ro"
                        ]
                      );
                      default = { };
                      example = {
                        family = "rw";
                      };
                      description = "Groups let into this share, by `selfhost.users.<name>.groups`. Additive: a principal holding several gets the most permissive. No `none` here, because a group grant is taken away per principal under `users`.";
                    };

                    users = lib.mkOption {
                      type = lib.types.attrsOf (
                        lib.types.enum [
                          "rw"
                          "ro"
                          "none"
                        ]
                      );
                      default = { };
                      example = {
                        machine-backup = "ro";
                        teenager = "none";
                      };
                      description = "Principals granted directly. Takes precedence over `groups` for that principal, so `none` revokes what a group gave. Every name must be a `selfhost.users` or `selfhost.serviceAccounts` entry with `storage.smb.enable`. Service accounts hold no groups, so they are always named here.";
                    };
                  };
                };
                default = { };
                description = "Who may reach this share, and at what level. Groups grant; a `users` entry overrides the group result for that principal.";
              };

              directories = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                example = [ "movies" ];
                description = "Paths under the share carrying its ownership. Plain ones are created; ones the host mounted keep their contents and only have ownership fixed.";
              };
            };
          }
        )
      );
      default = { };
      description = "Shares exported over SMB, keyed by the name clients connect to.";
    };
  };

  config = lib.mkIf (selfhostCfg.enable && cfg.enable) {
    warnings =
      let
        # A rebuilt root reallocates gids, and the data keeps the numbers already written into it.
        unpinned = lib.attrNames (lib.filterAttrs (_: s: s.gid == null) cfg.shares);
        heldGroups = lib.unique (lib.concatMap (name: selfhostCfg.users.${name}.groups or [ ]) (lib.attrNames principals));
        unheld = lib.subtractLists heldGroups (lib.intersectLists knownGroups grantedGroups);
      in
      lib.optional (unpinned != [ ])
        "SMB shares with no pinned gid: ${toString unpinned}. Read each back with `getent group` and set `selfhost.storage.shares.smb.shares.<name>.gid`."
      ++
        lib.optional (unheld != [ ])
          "SMB shares grant access to groups no SMB principal holds, so the grants resolve to nobody: ${toString unheld}. Set `storage.smb.enable` on the members, or grant the principals directly under `access.users`.";

    assertions =
      let
        unserved = lib.attrNames (lib.filterAttrs (name: _: resolved.${name} == { }) cfg.shares);
        ungranted = lib.filter (n: !(principals ? ${n})) userGrantees;
        unknownGroups = lib.subtractLists knownGroups grantedGroups;
        needUnixUser = lib.unique (lib.attrNames principals ++ lib.mapAttrsToList (_: s: s.owner) cfg.shares);
        missingUnixUser = lib.filter (n: !(config.users.users ? ${n})) needUnixUser;
        missingPassword = lib.attrNames (lib.filterAttrs (_: p: p.storage.smb.passwordFile == null) principals);
      in
      [
        {
          assertion = !(cfg.shares ? global);
          message = "A share cannot be named `global`: its settings would replace samba's global section, taking every hardening line with them.";
        }
        {
          assertion = unserved == [ ];
          message = "SMB shares whose `access` resolves to nobody: ${toString unserved}. Samba reads an empty `valid users` as no restriction, so the share would admit every principal that can authenticate.";
        }
        {
          assertion = ungranted == [ ];
          message = "SMB shares grant access to principals with no SMB account: ${toString ungranted}. Set `storage.smb.enable` on their selfhost.users or selfhost.serviceAccounts entry, or drop the grant; samba silently never matches a `valid users` name that cannot authenticate.";
        }
        {
          assertion = unknownGroups == [ ];
          message = "SMB shares grant access to groups nobody is in: ${toString unknownGroups}. `access.groups` names a `selfhost.groups` entry or a group some `selfhost.users` entry holds.";
        }
        {
          assertion = missingUnixUser == [ ];
          message = "SMB principals and share owners need a Unix user on this host; missing: ${toString missingUnixUser}. smbd drops to the connecting user, so the identity has to exist.";
        }
        {
          assertion = missingPassword == [ ];
          message = "SMB principals with no `storage.smb.passwordFile`: ${toString missingPassword}.";
        }
      ];

    users.groups = lib.mapAttrs' (
      name: share:
      lib.nameValuePair share.group {
        inherit (share) gid;
        members = lib.attrNames resolved.${name};
      }
    ) cfg.shares;

    services.samba = {
      enable = true;
      openFirewall = false; # opens 137/138/139 too, and netbios is off here
      nmbd.enable = false;
      winbindd.enable = false;
      settings = {
        global = {
          "server role" = "standalone server";
          "map to guest" = "Never";
          # "map to guest" still lets an anonymous session enumerate share names, which carry real names.
          "restrict anonymous" = "2";
          "server min protocol" = "SMB3";
          "disable netbios" = "yes";
          "smb ports" = "445"; # netbios is off, so do not listen on 139 either
        };
      }
      // lib.mapAttrs mkShare cfg.shares;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 445 ];

    # Needs node_exporter's systemd collector; without it the series is absent and this never fires.
    selfhost.monitoring.scopes.smb-shares.rules = [
      {
        name = "smb-shares";
        rules = [
          {
            alert = "SmbSharesUnserved";
            expr = ''node_systemd_unit_state{name=~"samba-smbd.service|selfhost-smb-permissions.service",state="failed"} == 1'';
            "for" = "5m";
            labels.severity = "critical";
            annotations.summary = "{{ $labels.name }} failed; SMB shares are not being served";
          }
        ];
      }
    ];

    systemd.services.selfhost-smb-permissions = {
      description = "Prepare SMB share ownership";
      wantedBy = [ "multi-user.target" ];
      before = [ "samba-smbd.service" ];
      # Fail rather than write into an unmounted share root.
      unitConfig.RequiresMountsFor = allOwnedPaths;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe setPermissions;
      };
    };

    systemd.services.selfhost-smb-passwords = {
      description = "Provision SMB passwords";
      before = [ "samba-smbd.service" ];
      requiredBy = [ "samba-smbd.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        LoadCredential = lib.mapAttrsToList (name: p: "${name}:${toString p.storage.smb.passwordFile}") principals;
        ExecStart = lib.getExe provisionPasswords;
      };
    };

    systemd.services.samba-smbd = {
      requires = [ "selfhost-smb-permissions.service" ];
      after = [ "selfhost-smb-permissions.service" ];
      unitConfig.RequiresMountsFor = allOwnedPaths;
    };
  };
}
