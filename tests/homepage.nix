# homepage (eval-only): the generatedTiles derivation groups opted-in services and externals, and excludes
# a service that opts out. Tests the framework's tile derivation — not the homepage-dashboard renderer.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;
  cfg = evalConfig {
    selfhost = {
      services.foo = {
        displayName = "Foo";
        port = 9001;
        integrations.homepage.group = "Media";
      };
      services.bar = {
        displayName = "Bar";
        port = 9002;
        integrations.homepage.enable = false; # opts out
      };
      external.nas = {
        displayName = "NAS";
        url = "http://nas.lan";
        integrations.homepage.group = "Admin";
      };
    };
  };

  tiles = cfg.selfhost.dashboards.generatedTiles;
  namesIn = group: map (t: builtins.head (builtins.attrNames t)) (tiles.${group} or [ ]);
  allNames = lib.concatMap namesIn (builtins.attrNames tiles);
in
assert lib.assertMsg (builtins.elem "Foo" (namesIn "Media")) "Foo missing from Media group";
assert lib.assertMsg (builtins.elem "NAS" (namesIn "Admin")) "external NAS missing from Admin group";
assert lib.assertMsg (!builtins.elem "Bar" allNames) "Bar opted out but still appears";
pkgs.runCommand "selfhost-homepage-eval" { } "touch $out"
