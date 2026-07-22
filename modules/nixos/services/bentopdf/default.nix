# First-party BentoPDF app: a static, client-side PDF toolkit served via darkhttpd behind selfhost
# ingress (nixpkgs services.bentopdf only wires nginx/caddy, which the ingress model doesn't use).
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost.services.bentopdf;
in
{
  options.selfhost.apps.bentopdf.enable =
    lib.mkEnableOption "the first-party BentoPDF app (static, client-side PDF toolkit)";

  config = lib.mkIf (config.selfhost.enable && config.selfhost.apps.bentopdf.enable) {
    selfhost.services.bentopdf = {
      displayName = lib.mkDefault "BentoPDF";
      meta.homepage = lib.mkDefault "https://www.bentopdf.com";
      meta.description = lib.mkDefault "PDF Toolkit";
      meta.category = lib.mkDefault "productivity";
      port = lib.mkDefault 8092;
    };

    systemd.services.bentopdf = {
      description = "BentoPDF static PDF toolkit";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        ExecStart = "${lib.getExe' pkgs.darkhttpd "darkhttpd"} ${pkgs.bentopdf} --addr ${cfg.host} --port ${toString cfg.port} --no-listing --no-server-id";
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "10s";
        RestartMaxDelaySec = "5min";
        RestartSteps = 5;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" ];
      };
    };
  };
}
