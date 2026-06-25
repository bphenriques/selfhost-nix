{
  lib,
  config,
  pkgs,
  ...
}:
let
  notifyCfg = config.selfhost.notify;
  sendNotification = "${notifyCfg.package}/bin/send-notification";

  tasksWithNotify = lib.filterAttrs (
    _: task: task.integrations.notify.enable && task.systemdServices != [ ]
  ) config.selfhost.tasks;

  notifyFailureScript = pkgs.writeShellScript "task-notify-failure" ''
    if [ "''${SERVICE_RESULT:-}" != "success" ]; then
      ${sendNotification} --topic "$NOTIFY_TOPIC" --title "Task Failed" \
        --message "$1 failed (''${SERVICE_RESULT:-unknown})" --priority high --tags x || true
    fi
  '';

  mkFailureOverrides =
    _: task:
    let
      inherit (task.integrations) notify;
      env = {
        NOTIFY_URL = notifyCfg.url;
        NOTIFY_TOPIC = notify.topic;
        NOTIFY_TOKEN_FILE = notify.tokenFile;
      };
    in
    lib.listToAttrs (
      map (
        svc:
        lib.nameValuePair svc {
          environment = env;
          serviceConfig.ExecStopPost = lib.mkAfter [ "${notifyFailureScript} ${svc}" ];
        }
      ) task.systemdServices
    );
in
{
  options.selfhost.notify = {
    enabled = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = config.selfhost.notify.url != "";
      defaultText = lib.literalMD "true once a provider sets `url`";
      description = "Whether a notify provider is active. Compose service defaults against this.";
    };

    topics = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.public = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the topic can be published without authentication";
          };
        }
      );
      default = { };
      description = "Notification topics and their visibility (framework subsystems self-register their own homelab-* topics).";
    };

    url = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Base URL of the notification endpoint; set by the active notify provider, consumed by send-notification (NOTIFY_URL).";
    };

    # Notification seam used by backup, task-failure hooks, and simple service hooks. Swap to
    # retarget all of them at once (e.g. an Apprise/gotify gateway). Producers that abstract
    # notifications themselves (Alertmanager, *arr connectors) stay native, retargeted in their config.
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.selfhost.send-notification;
      defaultText = lib.literalExpression "pkgs.selfhost.send-notification";
      description = "send-notification implementation. Contract: `send-notification --topic <t> --message <m> [--title <T>] [--priority <p>] [--tags <x>]`, reading NOTIFY_URL and NOTIFY_TOKEN_FILE from the env.";
    };
  };

  config = {
    assertions =
      let
        missingTopic = lib.filterAttrs (_: x: x.integrations.notify.enable && x.integrations.notify.topic == null);
        names = lib.attrNames (missingTopic config.selfhost.services) ++ lib.attrNames (missingTopic config.selfhost.tasks);
      in
      [
        {
          assertion = names == [ ];
          message = "integrations.notify.enable is set without a topic for: ${lib.concatStringsSep ", " names}. Set integrations.notify.topic.";
        }
      ];

    systemd.services = lib.mkMerge (lib.attrValues (lib.mapAttrs mkFailureOverrides tasksWithNotify));
  };
}
