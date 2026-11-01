# deSEC dynamic DNS for a WireGuard endpoint on a changing IP (see the apps chapter). Not for exposing services.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost.apps.desec;
in
{
  options.selfhost.apps.desec = {
    enable = lib.mkEnableOption "deSEC dynamic DNS updates";

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "File holding a deSEC API token authorized for `domains`.";
    };

    domains = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      example = [ "squirrel-plaza.dedyn.io" ];
      description = "Hostnames to keep pointed at the current public IP.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "30min";
      description = "Refresh period (systemd time span); a boot-time update also runs.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.desec-ddns = {
      description = "deSEC dynamic DNS update";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "desec-ddns";
        RuntimeDirectoryMode = "0700";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
      # -4 with myipv6=preserve keeps to the A record; the token goes through a printf'd curl config, never argv.
      path = [ pkgs.curl ];
      script = ''
        conf="$RUNTIME_DIRECTORY/curl.conf"
        printf 'header = "Authorization: Token %s"\n' "$(< ${cfg.tokenFile})" > "$conf"
        for host in ${lib.escapeShellArgs cfg.domains}; do
          curl -4 -fsS --retry 3 --max-time 30 \
            -K "$conf" \
            --url "https://update.dedyn.io/?hostname=$host&myipv6=preserve"
        done
      '';
    };

    # No topic default: OnFailure fires per 30-minute tick, so an outage would page on every one.
    selfhost.tasks.desec-ddns.systemdServices = [ "desec-ddns" ];

    # A stale A record shows only when resolution fails, so alert, with `for` spanning one retry.
    selfhost.monitoring.scopes = lib.mkIf config.selfhost.monitoring.enable {
      desec-ddns.rules = [
        {
          name = "desec-ddns";
          rules = [
            {
              alert = "DynamicDnsStale";
              expr = ''node_systemd_unit_state{name="desec-ddns.service",state="failed"} == 1'';
              "for" = "45m";
              labels.severity = "critical";
              annotations.summary = "deSEC updates are failing; {{ $labels.instance }}'s hostnames are going stale";
            }
          ];
        }
      ];
    };

    systemd.timers.desec-ddns = {
      description = "Periodic deSEC dynamic DNS update";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = cfg.interval;
      };
    };
  };
}
