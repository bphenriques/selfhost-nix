# *arr apps (eval-only): enabling radarr/sonarr/prowlarr registers the service with framework wiring, a
# reconcile unit (media arrs only), an API-key secret + env template, a backup hook, and a failure-notify
# task — while shipping no acquisition config. Pure derivations; no VM boot.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;
  cfg = evalConfig {
    selfhost.apps = {
      radarr = {
        enable = true;
        rootFolders = [ { path = "/mnt/media/movies"; } ];
        downloadClients = [
          {
            name = "Transmission";
            implementation = "Transmission";
            protocol = "torrent";
            fields = {
              host = "127.0.0.1";
              port = 9091;
              urlBase = "/transmission/";
              movieCategory = "radarr";
            };
          }
        ];
        delayProfile.preferredProtocol = "torrent";
      };
      sonarr.enable = true;
      prowlarr.enable = true;
    };
  };

  svc = cfg.selfhost.services;
  units = cfg.systemd.services;
in
assert lib.assertMsg (svc.radarr.healthcheck.path == "/ping") "radarr healthcheck path not /ping";
assert lib.assertMsg (svc.radarr.access.allowedGroups == [ "admin" ]) "radarr should default to admin group";
assert lib.assertMsg (svc.radarr.backup.package != null) "radarr should register a backup hook";
assert lib.assertMsg (units ? "radarr-configure") "radarr reconcile unit missing";
assert lib.assertMsg (cfg.selfhost.runtimeSecrets ? "radarr-api-key") "radarr api-key secret missing";
assert lib.assertMsg (cfg.selfhost.runtimeTemplates ? "radarr.env") "radarr env template missing";
assert lib.assertMsg (cfg.selfhost.tasks ? "radarr-configure") "radarr failure-notify task missing";
assert lib.assertMsg (svc.sonarr.healthcheck.path == "/ping") "sonarr not registered";
# Prowlarr is wiring-only: registered, but no reconcile unit and no root-folder surface.
assert lib.assertMsg (svc ? prowlarr) "prowlarr not registered";
assert lib.assertMsg (!(units ? "prowlarr-configure")) "prowlarr must not have a reconcile unit";
assert lib.assertMsg (
  cfg.selfhost.apps.radarr.apiKeyFile == cfg.selfhost.runtimeSecrets."radarr-api-key".path
) "apiKeyFile should expose the secret path";
pkgs.runCommand "selfhost-arr-eval" { } "touch $out"
