# SMB file server, the counterpart to `storage.mounts.smb` on the client. The backing store stays the
# host's, and so does ownership of what is in it: `path` points at what the host already mounted and
# prepared, and this only exports it and decides who gets in.
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
  smbUsers = lib.filterAttrs (_: p: p.storage.smb.enable) selfhostCfg.users;
  smbServiceAccounts = lib.filterAttrs (_: p: p.storage.smb.enable) selfhostCfg.serviceAccounts;
  principals = smbUsers // smbServiceAccounts;

  knownGroups = selfhostLib.knownGroups selfhostCfg;

  levelRank = {
    ro = 1;
    rw = 2;
  };

  groupLevel =
    share: name:
    let
      granted = lib.filter (level: level != null) (
        map (group: share.access.groups.${group} or null) selfhostCfg.users.${name}.groups
      );
    in
    if granted == [ ] then "none" else lib.head (lib.sort (a: b: levelRank.${a} > levelRank.${b}) granted);

  # A `users` grant replaces whatever the groups produced for that person, `none` included.
  resolve =
    share:
    lib.filterAttrs (_: level: level != "none") (
      lib.mapAttrs (name: _: share.access.users.${name} or (groupLevel share name)) smbUsers
    )
    // lib.filterAttrs (name: _: smbServiceAccounts ? ${name}) share.access.serviceAccounts;

  grantedUsers = lib.unique (lib.concatMap (s: lib.attrNames s.access.users) (lib.attrValues cfg.shares));
  grantedServiceAccounts = lib.unique (
    lib.concatMap (s: lib.attrNames s.access.serviceAccounts) (lib.attrValues cfg.shares)
  );
  grantedGroups = lib.unique (lib.concatMap (s: lib.attrNames s.access.groups) (lib.attrValues cfg.shares));

  mkShare =
    _: share:
    let
      readOnly = lib.attrNames (lib.filterAttrs (_: level: level == "ro") share.resolvedAccess);
    in
    lib.optionalAttrs (readOnly != [ ]) { "read list" = lib.concatStringsSep " " readOnly; }
    // {
      inherit (share) path;
      browseable = "yes";
      "read only" = "no";
      "valid users" = lib.concatStringsSep " " (lib.attrNames share.resolvedAccess);
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
          { config, ... }:
          {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                example = "/srv/storage/media";
                description = "Absolute path exported under this share name. The host prepares and mounts it, ownership included; this module never touches what is there. Two shares may open onto one tree.";
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
                      description = "Groups let into this share, by `selfhost.users.<name>.groups`. Additive: a person holding several gets the most permissive. No `none` here, because a group grant is taken away per person under `users`.";
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
                        teenager = "none";
                      };
                      description = "People granted directly, by `selfhost.users` name. Takes precedence over `groups` for that person, so `none` revokes what a group gave.";
                    };

                    serviceAccounts = lib.mkOption {
                      type = lib.types.attrsOf (
                        lib.types.enum [
                          "rw"
                          "ro"
                        ]
                      );
                      default = { };
                      example = {
                        machine-backup = "ro";
                      };
                      description = "Service accounts granted, by `selfhost.serviceAccounts` name. They hold no groups, so this is their only way in, and there is nothing for `none` to revoke.";
                    };
                  };
                };
                default = { };
                description = "Who may reach this share, and at what level. Every name must have `storage.smb.enable` in its registry.";
              };

              resolvedAccess = lib.mkOption {
                type = lib.types.attrsOf (
                  lib.types.enum [
                    "rw"
                    "ro"
                  ]
                );
                readOnly = true;
                default = resolve config;
                defaultText = lib.literalMD "`access`, with groups expanded and `none` dropped";
                description = "Every principal let in, and at what level: what reaches `valid users` and `read list`. Read it to give the host's own groups the same members.";
              };
            };
          }
        )
      );
      default = { };
      description = "Shares exported over SMB, keyed by the name clients connect to.";
    };
  };

  config = lib.mkIf cfg.enable {
    warnings =
      let
        heldGroups = lib.unique (lib.concatMap (name: selfhostCfg.users.${name}.groups) (lib.attrNames smbUsers));
        unheld = lib.subtractLists heldGroups (lib.intersectLists knownGroups grantedGroups);
      in
      lib.optional (unheld != [ ])
        "SMB shares grant access to groups no SMB principal holds, so the grants resolve to nobody: ${toString unheld}. Set `storage.smb.enable` on the members, or grant them directly under `access.users`.";

    assertions =
      let
        unserved = lib.attrNames (lib.filterAttrs (_: s: s.resolvedAccess == { }) cfg.shares);
        ungrantedUsers = lib.filter (n: !(smbUsers ? ${n})) grantedUsers;
        ungrantedServiceAccounts = lib.filter (n: !(smbServiceAccounts ? ${n})) grantedServiceAccounts;
        unknownGroups = lib.subtractLists knownGroups grantedGroups;
        missingUnixUser = lib.filter (n: !(config.users.users ? ${n})) (lib.attrNames principals);
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
          assertion = ungrantedUsers == [ ];
          message = "SMB shares grant `access.users` to names that are not people with an SMB account: ${toString ungrantedUsers}. Set `storage.smb.enable` on their selfhost.users entry, or grant a service account under `access.serviceAccounts`; samba silently never matches a name that cannot authenticate.";
        }
        {
          assertion = ungrantedServiceAccounts == [ ];
          message = "SMB shares grant `access.serviceAccounts` to names that are not service accounts with an SMB account: ${toString ungrantedServiceAccounts}. Set `storage.smb.enable` on their selfhost.serviceAccounts entry, or grant a person under `access.users`.";
        }
        {
          assertion = unknownGroups == [ ];
          message = "SMB shares grant access to groups nobody is in: ${toString unknownGroups}. `access.groups` names a `selfhost.groups` entry or a group some `selfhost.users` entry holds.";
        }
        {
          assertion = missingUnixUser == [ ];
          message = "SMB principals need a Unix user on this host; missing: ${toString missingUnixUser}. smbd drops to the connecting user, so the identity has to exist.";
        }
      ];

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
          # An authenticated session enumerates every share too, not just an anonymous one.
          "access based share enum" = "yes";
          "server min protocol" = "SMB3";
          "disable netbios" = "yes";
          "smb ports" = "445"; # netbios is off, so do not listen on 139 either
        };
      }
      // lib.mapAttrs mkShare cfg.shares;
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 445 ];

    selfhost.internal.listeningPorts = [
      {
        name = "samba/smbd";
        host = "0.0.0.0";
        port = 445;
      }
    ];

    # Needs node_exporter's systemd collector; without it the series is absent and this never fires.
    # Gated on the concern: with Prometheus off this renders nowhere, so declare nothing.
    selfhost.monitoring.scopes = lib.mkIf selfhostCfg.monitoring.enable {
      smb-shares.rules = [
        {
          name = "smb-shares";
          rules = [
            {
              alert = "SmbSharesUnserved";
              expr = ''node_systemd_unit_state{name="samba-smbd.service",state="failed"} == 1'';
              "for" = "5m";
              labels.severity = "critical";
              annotations.summary = "{{ $labels.name }} failed; SMB shares are not being served";
            }
          ];
        }
      ];
    };

    # Only for principals still on the default path: one that supplies its own needs nothing generated.
    selfhost.runtimeSecrets =
      lib.mapAttrs'
        (
          pname: _p:
          lib.nameValuePair "smb-password-${pname}" {
            bytes = 12; # typed into a device by hand
            restartUnits = [ "selfhost-smb-passwords.service" ];
          }
        )
        (
          lib.filterAttrs (
            pname: p: p.storage.smb.passwordFile == "${selfhostCfg.runtimeSecretsDir}/smb-password-${pname}"
          ) principals
        );

    # Every hardening line but the filesystem sandbox: samba's passdb is consumer-relocatable, and a
    # ReadWritePaths that misses it fails at the write rather than at start.
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
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    # Fail rather than serve whatever sits on the root filesystem under an unmounted share.
    systemd.services.samba-smbd.unitConfig.RequiresMountsFor = lib.mapAttrsToList (_: s: s.path) cfg.shares;
  };
}
