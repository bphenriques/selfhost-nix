# Deliberate OIDC client-secret rotation: an oidc-rotate CLI (always) and an opt-in timer.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost.auth.oidc.rotation;
  oidcCfg = config.selfhost.auth.oidc;
  prefix = oidcCfg.systemd.clientProvisionUnitPrefix; # provider-agnostic unit name (null until a provider sets it)
  clientNames = lib.attrNames oidcCfg.clients;
  hasRotation = prefix != null && clientNames != [ ];

  oidc-rotate = pkgs.writeShellApplication {
    name = "oidc-rotate";
    runtimeInputs = [
      pkgs.systemd
      pkgs.coreutils
    ];
    text = ''
      # oidc-rotate [<client>] — rotate one client, or all when no argument is given.
      rotate_one() {
        local c="$1"
        echo "Rotating OIDC client secret: $c"
        rm -f "${oidcCfg.credentials.dir}/$c/secret"   # rotate-when-missing regenerates it
        systemctl restart "${prefix}$c.service"         # → cascades to the client's consumers
      }
      if [ "$#" -eq 0 ]; then
        # shellcheck disable=SC2043  # the client list is generated and may have one or many entries
        for c in ${lib.escapeShellArgs clientNames}; do rotate_one "$c"; done
      else
        rotate_one "$1"
      fi
    '';
  };
in
{
  options.selfhost.auth.oidc.rotation = {
    enable = lib.mkEnableOption "a timer that rotates all OIDC client secrets on a schedule";

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "Sun *-*-* 03:00:00";
      example = "monthly";
      description = "systemd OnCalendar expression for the rotation timer (default: weekly, Sunday 03:00).";
    };

    notifyTopic = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "selfhost.notify topic to alert on if a scheduled rotation fails (null = no alert).";
    };
  };

  config = lib.mkMerge [
    # On-demand rotation is always available wherever there are clients to rotate.
    (lib.mkIf hasRotation {
      environment.systemPackages = [ oidc-rotate ];
    })

    (lib.mkIf (cfg.enable && hasRotation) {
      systemd.services.oidc-rotate = {
        description = "Rotate OIDC client secrets";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe oidc-rotate;
        };
      };

      systemd.timers.oidc-rotate = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = cfg.schedule;
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };

      # Alert on failure via the notify integration (notify/notify.nix attaches the failure hook to this task's unit).
      selfhost.tasks.oidc-rotate = {
        systemdServices = [ "oidc-rotate" ];
        integrations.notify.topic = cfg.notifyTopic;
      };
    })
  ];
}
