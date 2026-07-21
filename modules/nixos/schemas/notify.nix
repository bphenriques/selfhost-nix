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
            default = selfhostCfg.notify.active && config.topic != null;
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
            description = ''
              Path to this publisher's access token, provisioned root-owned `0400`. How a publisher reads it
              depends on its user:

              - **runs as root** (e.g. backup, task failure-hooks): read this path directly, at send time.
                Best-effort — no dependency on the provider being up, so notify never blocks the publisher.
              - **runs as a non-root user** (e.g. transmission): receive it via systemd
                `LoadCredential = [ "notify-token:''${...tokenFile}" ]` and read `%d/notify-token`
                (`$CREDENTIALS_DIRECTORY/notify-token`). Because LoadCredential reads the source at unit
                start, order the unit `after` the provider's provisioning unit (`selfhost.notify.provisioningUnit`).
            '';
          };
        };
      }
    );
    default = { };
    description = "notification integration";
  };
}
