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
    type = lib.types.submodule (
      { config, ... }:
      {
        options = {
          # Composes with the concern: on once a notify provider is active and a topic is named.
          enable = lib.mkOption {
            type = lib.types.bool;
            default = selfhostCfg.notify.enabled && config.topic != null;
            defaultText = lib.literalMD "on when a notify provider is active and `topic` is set";
            description = "Publish notifications for this service/task.";
          };

          topic = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum (lib.attrNames selfhostCfg.notify.topics));
            default = null;
            description = "Notification topic this service/task publishes to (null = none).";
          };

          tokenFile = lib.mkOption {
            type = lib.types.str;
            default = "${tokenDir}/${name}";
            readOnly = true;
            description = "Path to the generated access token file for this publisher";
          };
        };
      }
    );
    default = { };
    description = "notification integration";
  };
}
