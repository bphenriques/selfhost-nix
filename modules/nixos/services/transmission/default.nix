# First-party Transmission app: the torrent client wired into selfhost (ingress, forward-auth, and
# download notifications). Deployment specifics — download/incomplete dirs, seeding/ratio tuning, the
# storage backing — stay with the consumer; those are nixpkgs `services.transmission` options we don't proxy.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  app = config.selfhost.apps.transmission;
  serviceCfg = config.selfhost.services.transmission;
  notifyCfg = config.selfhost.notify;
  notify = serviceCfg.integrations.notify;

  # Transmission spawns these as subprocesses that don't inherit $CREDENTIALS_DIRECTORY, so point at the
  # credential's stable path directly — LoadCredential (below) makes it readable by the transmission user.
  torrentNotify =
    { title, tags }:
    pkgs.writeShellScript "transmission-notify" ''
      NOTIFY_URL=${notifyCfg.url} NOTIFY_TOKEN_FILE=/run/credentials/transmission.service/notify-token \
        ${notifyCfg.package}/bin/send-notification \
        --topic ${toString notify.topic} --title "${title}" --tags "${tags}" --message "$TR_TORRENT_NAME"
    '';
in
{
  options.selfhost.apps.transmission.enable = lib.mkEnableOption "the first-party Transmission app (torrent client)";

  config = lib.mkIf (config.selfhost.enable && app.enable) {
    selfhost.services.transmission = {
      displayName = lib.mkDefault "Transmission";
      meta.homepage = lib.mkDefault "https://transmissionbt.com";
      meta.description = lib.mkDefault "Torrent Client";
      meta.category = lib.mkDefault "downloads";
      port = lib.mkDefault 9091;
      healthcheck.path = "/transmission/web/";
      access.allowedGroups = lib.mkDefault [ config.selfhost.groups.admin ];
      forwardAuth.enable = lib.mkDefault config.selfhost.auth.forwardAuth.active; # follows the gateway being active
      # Sane default topic when one exists; consumers with a different taxonomy override it.
      integrations.notify.topic = lib.mkDefault (if notifyCfg.topics ? "downloads" then "downloads" else null);
    };

    services.transmission = {
      enable = true;
      settings = {
        rpc-bind-address = "127.0.0.1"; # forwardAuth gates ingress; localhost is the only pre-auth surface
        rpc-port = serviceCfg.port;
        rpc-host-whitelist-enabled = true;
        rpc-host-whitelist = serviceCfg.publicHost;
      }
      // lib.optionalAttrs notify.enable {
        script-torrent-added-enabled = true;
        script-torrent-added-filename = toString (torrentNotify {
          title = "Download Started";
          tags = "arrow_down";
        });
        script-torrent-done-enabled = true;
        script-torrent-done-filename = toString (torrentNotify {
          title = "Download Complete";
          tags = "white_check_mark";
        });
      };
    };

    systemd.services.transmission = {
      # LoadCredential reads the token at unit start, so wait for the provider to provision it first.
      after = lib.optional (notify.enable && notifyCfg.provisioningUnit != null) notifyCfg.provisioningUnit;
      wants = lib.optional (notify.enable && notifyCfg.provisioningUnit != null) notifyCfg.provisioningUnit;
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        RestartMaxDelaySec = "5min";
        RestartSteps = 5;
        LoadCredential = lib.optionals notify.enable [ "notify-token:${notify.tokenFile}" ];
      };
    };
  };
}
