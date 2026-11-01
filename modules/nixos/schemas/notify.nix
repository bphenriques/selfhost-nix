{
  name,
  lib,
  selfhostCfg,
  # notify.defaultTopic for a task, null for a service: see the comments where each registry passes it.
  notifyDefaultTopic,
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
            default = notifyDefaultTopic;
            defaultText = lib.literalMD "`notify.defaultTopic` for a task, null for a service";
            description = "Notification topic this service/task publishes to (null = none). A task falls back to `notify.defaultTopic`, since the hook reporting its failure is the framework's own; a service names one when it has something to say.";
          };

          # Topic is all a subscriber can mute, so split by urgency rather than by subsystem.
          failureTopic = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum (lib.attrNames selfhostCfg.notify.topics));
            default = config.topic;
            defaultText = lib.literalMD "`topic`";
            description = "Topic for task-failure notifications. Defaults to `topic`; point it somewhere louder to separate failures from routine summaries. The publisher is granted write on both.";
          };

          titlePrefix = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Prepended to failure-notification titles as `<prefix>: `. Set it when several hosts publish to one topic, where the unit name alone does not say which host failed.";
          };

          tokenFile = lib.mkOption {
            type = lib.types.str;
            default = "${tokenDir}/${name}";
            description = "Root-owned path to this publisher's access token. Non-root publishers receive it via `LoadCredential` (see the security chapter).";
          };
        };
      }
    );
    default = { };
    description = "notification integration";
  };
}
