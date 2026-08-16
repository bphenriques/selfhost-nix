# One eval check per app, each enabled *alone* against a bare framework. Granular on purpose: a broken
# app fails its own check by name rather than one shared "everything" check that stops at the first
# problem and names none of them.
#
# Alone and with no auth provider is the honest worst case — it is what a first `apps.<name>.enable = true`
# looks like, and it is where the interesting failures live: a missing precondition surfacing as a raw
# module error, an app that half-wires its backend, or one that would route with nothing authenticating it.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  stub = "/run/secrets/stub";

  # Extra config an app needs before it can evaluate at all (paths it must be told, not defaults).
  apps = {
    bazarr.apiKeyFile = stub;
    bentopdf = { };
    desec = {
      tokenFile = stub;
      domains = [ "test.local" ];
    };
    filebrowser = { };
    gitea = { };
    homepage = { };
    immich = { };
    jellyfin = { };
    miniflux = { };
    prowlarr = { };
    radarr = { };
    radicale = { };
    sonarr = { };
    transmission = { };
    wireguard = {
      address = "10.100.0.1/24";
      clientSubnet = "10.100.0.0/24";
      endpoint = "vpn.test.local";
      dns = "10.100.0.1";
      name = "test";
    };
  };

  mkAppCheck =
    name: extra:
    let
      cfg = evalConfig {
        selfhost.apps.${name} = {
          enable = true;
        }
        // extra;
      };
      failed = lib.filter (a: !a.assertion) cfg.assertions;
      # Not every app registers under its own name (none currently differ, but don't assume).
      entry = cfg.selfhost.services.${name} or null;
    in
    assert lib.assertMsg (failed == [ ]) "apps.${name} alone: ${lib.concatMapStringsSep "; " (a: a.message) failed}";
    assert lib.assertMsg (cfg.system.build.toplevel.drvPath != null) "apps.${name} alone must evaluate";
    # The property the whole access model exists to guarantee: nothing that authenticates nobody goes up
    # on a host with no gateway to authenticate for it.
    assert lib.assertMsg (
      entry == null || entry.access.model != "forwardAuth" || !entry.ingress.enable
    ) "apps.${name} declares access.model = \"forwardAuth\" but is routed with no provider active";
    pkgs.runCommand "selfhost-app-${name}-eval" { } "touch $out";
in
lib.mapAttrs' (name: extra: lib.nameValuePair "app-${name}-eval" (mkAppCheck name extra)) apps
