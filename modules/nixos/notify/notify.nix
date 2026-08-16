{
  lib,
  config,
  options,
  pkgs,
  ...
}:
let
  notifyCfg = config.selfhost.notify;
  sendNotification = "${notifyCfg.package}/bin/send-notification";

  tasksWithNotify = lib.filterAttrs (
    _: task: task.integrations.notify.enable && task.systemdServices != [ ]
  ) config.selfhost.tasks;

  # `OnFailure` rather than an `ExecStopPost` hook, so this fires when systemd gives up rather than on
  # every failed attempt: a unit with `Restart=on-failure` only reaches the failed state once its start
  # limit is exhausted. A unit that does not restart still alerts on its first failure, as it should.
  # One notifier per task (its topic and token differ), instanced by `%n` so the message names the unit.
  notifierUnit = taskName: "homelab-notify-failure-${taskName}@";

  mkNotifier =
    taskName: task:
    lib.nameValuePair (notifierUnit taskName) {
      description = "Notify that %i failed";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = ''
          ${sendNotification} --topic ${lib.escapeShellArg task.integrations.notify.topic} \
            --title "Task Failed" --message "%i failed" --priority high --tags x
        '';
        LoadCredential = [ "notify-token:${task.integrations.notify.tokenFile}" ];
      };
      environment = {
        NOTIFY_URL = notifyCfg.url;
        NOTIFY_TOKEN_FILE = "%d/notify-token";
      };
    };

  mkFailureOverrides =
    taskName: task:
    lib.listToAttrs (
      map (svc: lib.nameValuePair svc { onFailure = [ "${notifierUnit taskName}%n.service" ]; }) task.systemdServices
    );
in
{
  options.selfhost.notify = {
    active = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = options.selfhost.notify.url.isDefined;
      defaultText = lib.literalMD "true once a provider defines `url`";
      description = "Whether a notify provider is active. Compose service defaults against this.";
    };

    topics = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.public = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the topic can be *read* without authentication (grants `everyone ro`). Publishing always needs a per-service token, so this decides who can see the messages, not who can send them.";
          };
        }
      );
      default = { };
      description = "Notification topics and their visibility (framework subsystems self-register their own homelab-* topics).";
    };

    url = lib.mkOption {
      type = lib.types.str;
      description = "Base URL of the notification endpoint, set by the active notify provider and consumed by send-notification (NOTIFY_URL). Left undefined until one is, which is what `active` reads.";
    };

    provisioningUnit = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Systemd unit of the active provider that provisions publisher tokens; consumers that read a token via LoadCredential order `after` it. null = no provider, or a provider with no provisioning step.";
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

    systemd.services = lib.mkMerge (
      lib.attrValues (lib.mapAttrs mkFailureOverrides tasksWithNotify) ++ [ (lib.mapAttrs' mkNotifier tasksWithNotify) ]
    );
  };
}
