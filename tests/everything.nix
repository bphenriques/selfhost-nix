# Composition: every app and provider enabled together. Deliberately narrow — whether an app evaluates
# at all is `tests/apps.nix`, one check per app, because that feedback should name the app. What is left
# here is only what needs the whole surface at once: cross-service uniqueness (hosts, ports), and the
# consumer-facing derivations that fold every entry into one value and so cannot be checked per app.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  stub = "/run/secrets/stub";

  # A function module, so `backup.package` resolves against the overlaid pkgs inside the config.
  cfg = evalConfig (
    { config, pkgs, ... }:
    {
      selfhost = {
        mail = {
          host = "smtp.test.local";
          from = "selfhost@test.local";
          user = "selfhost";
          passwordFile = stub;
        };

        ingress = {
          traefik.enable = true;
          acme = {
            email = "admin@test.local";
            dnsProvider = "cloudflare";
            credentialsEnvFile = stub;
          };
        };

        auth = {
          oidc.pocket-id.enable = true;
          oidc.rotation.enable = true;
          forwardAuth.tinyauth.enable = true;
        };

        notify.ntfy.enable = true;

        monitoring = {
          enable = true;
          alertmanager.enable = true;
        };

        storage.mounts.smb = {
          enable = true;
          hostname = "192.168.1.10";
          credentialsPath = stub;
          shares.media.gid = 5001;
        };

        backup = {
          targets.local = {
            repository = "/var/lib/homelab-backup";
            passwordFile = stub;
            retention = {
              daily = "7 days";
              weekly = "1 month";
              monthly = "1 year";
              yearly = "2 years";
            };
            # Derived, so a newly added backup hook is covered here instead of going stale.
            services = lib.attrNames (lib.filterAttrs (_: s: s.backup.package != null) config.selfhost.services);
          };
        };

        apps = {
          bazarr = {
            enable = true;
            apiKeyFile = stub;
          };
          bentopdf.enable = true;
          desec = {
            enable = true;
            tokenFile = stub;
            domains = [ "test.local" ];
          };
          filebrowser.enable = true;
          gitea.enable = true;
          homepage.enable = true;
          immich.enable = true;
          jellyfin.enable = true;
          miniflux.enable = true;
          prowlarr.enable = true;
          radarr.enable = true;
          radicale.enable = true;
          sonarr.enable = true;
          transmission.enable = true;
          wireguard = {
            enable = true;
            address = "10.100.0.1/24";
            clientSubnet = "10.100.0.0/24";
            endpoint = "vpn.test.local";
            dns = "10.100.0.1";
            name = "test";
          };
        };

        users.admin.services = {
          filebrowser = {
            enable = true;
            storage.media = "rw";
          };
          gitea.enable = true;
          immich.enable = true;
          jellyfin.enable = true;
          radicale.enable = true;
          wireguard = {
            enable = true;
            devices = [
              {
                name = "laptop";
                ip = "10.100.0.42";
                publicKey = "0000000000000000000000000000000000000000000=";
              }
            ];
          };
        };
      };
    }
  );

  failed = lib.filter (a: !a.assertion) cfg.assertions;
in
# The uniqueness assertions (public hosts, listening ports) only have anything to compare with the whole
# set enabled, and are the reason this check exists at all.
assert lib.assertMsg (failed == [ ]) "assertions fired: ${lib.concatMapStringsSep "; " (a: a.message) failed}";
assert lib.assertMsg (cfg.system.build.toplevel.drvPath != null) "the full surface must evaluate";
# Read only by consumers, and each folds every registry entry into one value, so nothing per-app forces them.
assert lib.assertMsg (builtins.deepSeq cfg.selfhost.inventory true) "inventory must evaluate";
assert lib.assertMsg (builtins.deepSeq cfg.selfhost.dashboards.generatedTiles true) "tiles must evaluate";
pkgs.runCommand "selfhost-everything-eval" { } "touch $out"
