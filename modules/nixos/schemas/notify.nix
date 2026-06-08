{
  name,
  lib,
  selfhostCfg,
  ...
}:
let
  tokenDir = "/var/lib/homelab-secrets/notify-publishers";
in
{
  options.integrations.notify = lib.mkOption {
    type = lib.types.submodule {
      options = {
        enable = lib.mkEnableOption "notifications";

        topic = lib.mkOption {
          type = lib.types.enum (lib.attrNames selfhostCfg.notify.topics);
          description = "Notification topic this service/task publishes to";
        };

        tokenFile = lib.mkOption {
          type = lib.types.str;
          default = "${tokenDir}/${name}";
          readOnly = true;
          description = "Path to the generated access token file for this publisher";
        };
      };
    };
    default = { };
    description = "notification integration";
  };
}
