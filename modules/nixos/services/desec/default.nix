# deSEC dynamic DNS: keeps `domains` pointed at the host's current public IP.
#
# A good fit for reaching a WireGuard server on a residential connection whose IP changes — clients
# dial a stable hostname instead of a moving IP. WireGuard is silent (it never answers an
# unauthenticated packet), so a published home IP is invisible to scanners and offers nothing to
# hit. Don't use this to expose services directly: that means opening ports, which the WireGuard
# stealth property no longer covers.
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
      };
      # deSEC autodetects the IP from the request source, so there's nothing to detect locally; -4
      # (+ myipv6=preserve) keeps us to the A record and never clobbers an AAAA. The token is written
      # to a curl config with printf (a bash builtin, so it never lands in a process's argv) and read
      # back via -K, keeping it off the command line.
      script = ''
        conf="$RUNTIME_DIRECTORY/curl.conf"
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
