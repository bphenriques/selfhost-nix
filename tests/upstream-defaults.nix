# The framework must not silently drop a nixpkgs option default. An `attrsOf` option's `default` is
# discarded the moment anything defines it, so an app that sets one key of `services.<x>.settings` can
# quietly undo values upstream shipped — Open WebUI's telemetry opt-outs live exactly there.
#
# For each attrs-option an app defines, compare the keys nixpkgs would have defaulted against the keys
# that survive once the app is enabled. Anything lost has to be restated deliberately, or it is a bug.
{
  pkgs,
  evalConfig,
  bareConfig,
}:
let
  inherit (pkgs) lib;

  keysOf =
    cfg: svc: opt:
    let
      v = lib.getAttrFromPath [ "services" svc opt ] cfg;
    in
    if builtins.isAttrs v then lib.attrNames v else [ ];

  dropped =
    {
      app,
      svc,
      opt,
    }:
    let
      before = keysOf (bareConfig { services.${svc}.enable = true; }) svc opt;
      after = keysOf (evalConfig {
        selfhost = {
          mail = {
            host = "s";
            from = "a@t.l";
            user = "u";
            passwordFile = "/run/s";
          };
          auth.oidc.pocket-id.enable = true;
          apps.${app}.enable = true;
        };
      }) svc opt;
    in
    lib.nameValuePair "services.${svc}.${opt}" (lib.subtractLists after before);

  results = lib.listToAttrs (
    map dropped [
      {
        app = "open-webui";
        svc = "open-webui";
        opt = "environment";
      }
      {
        app = "gitea";
        svc = "gitea";
        opt = "settings";
      }
      {
        app = "miniflux";
        svc = "miniflux";
        opt = "config";
      }
      {
        app = "radicale";
        svc = "radicale";
        opt = "settings";
      }
      {
        app = "transmission";
        svc = "transmission";
        opt = "settings";
      }
      {
        app = "immich";
        svc = "immich";
        opt = "settings";
      }
      {
        app = "romm";
        svc = "romm";
        opt = "extraEnvironment";
      }
    ]
  );

  offenders = lib.filterAttrs (_: d: d != [ ]) results;
in
assert lib.assertMsg (offenders == { })
  "Upstream option defaults dropped by the framework: ${
    lib.concatStringsSep "; " (lib.mapAttrsToList (o: keys: "${o} lost ${toString keys}") offenders)
  }. Restate them in the app with a comment saying why, or stop defining the option.";
pkgs.runCommand "selfhost-upstream-defaults-eval" { } "touch $out"
