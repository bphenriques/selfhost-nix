{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost.ddns.desec;
in
{
  options.selfhost.ddns.desec = {
    enable = lib.mkEnableOption "deSEC dynamic DNS (keep A records pointed at the current public IP)";

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = "Runtime path to a file holding a deSEC API token authorized to write the domains' records.";
    };

    domains = lib.mkOption {
      type = lib.types.nonEmptyListOf lib.types.str;
      example = [ "squirrel-plaza.dedyn.io" ];
      description = "Hostnames whose A record is kept current.";
    };

    interval = lib.mkOption {
      type = lib.types.str;
      default = "30min";
      description = "Refresh period (systemd time span). A boot-time update (OnBootSec) catches IP changes that come with a reconnect; this periodic refresh is the backstop. deSEC tolerates unchanged ('nochg') updates.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.desec-ddns = {
      description = "deSEC dynamic DNS update";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
      # deSEC autodetects the IP from the request source, so there's nothing to detect locally; -4
      # (+ myipv6=preserve) keeps us to the A record and never clobbers an AAAA. The token is written
      # to a curl config with printf (a bash builtin, so it never lands in a process's argv) and read
      # back via -K, keeping it off the command line.
      script = ''
        conf="$(mktemp)"
        trap 'rm -f "$conf"' EXIT
        printf 'header = "Authorization: Token %s"\n' "$(< ${cfg.tokenFile})" > "$conf"
        for host in ${lib.escapeShellArgs cfg.domains}; do
          ${pkgs.curl}/bin/curl -4 -fsS --retry 3 --max-time 30 \
            -K "$conf" \
            --url "https://update.dedyn.io/?hostname=$host&myipv6=preserve"
        done
      '';
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
