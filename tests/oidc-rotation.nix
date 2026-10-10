# auth.oidc.rotation (eval-only): with a provider prefix set and at least one OIDC client, enabling rotation
# wires a oneshot + timer on the schedule plus a failure-notify task. No VM — real rotation needs a running
# provider; this covers the pure wiring. clientProvisionUnitPrefix stands in for what a provider sets.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;
  cfg = evalConfig {
    selfhost = {
      auth.oidc = {
        systemd.clientProvisionUnitPrefix = "test-provision-"; # a provider normally sets this
        rotation = {
          enable = true;
          schedule = "monthly";
        };
      };
      # A service with an OIDC client gives rotation something to rotate.
      services.app = {
        port = 8081;
        access.model = "oidc";
      };
      # Topics are the consumer's to name, so rotation only publishes once one is pointed at it.
      notify.topics.ops.public = false;
      tasks.oidc-rotate.integrations.notify.topic = "ops";
    };
  };
in
assert lib.assertMsg (cfg.systemd.services ? oidc-rotate) "oidc-rotate service not registered";
assert lib.assertMsg (cfg.systemd.timers ? oidc-rotate) "oidc-rotate timer not registered";
assert lib.assertMsg (
  cfg.systemd.timers.oidc-rotate.timerConfig.OnCalendar == "monthly"
) "rotation schedule not wired to the timer";
assert lib.assertMsg (cfg.selfhost.tasks ? oidc-rotate) "rotation failure-notify task missing";
# The task exists either way; pointing a topic at it is what arms the failure hook once a provider is
# active, so a silent rotation failure (clients holding secrets the provider no longer accepts) is the
# consumer's choice rather than a name this module picked.
assert lib.assertMsg (
  cfg.selfhost.tasks.oidc-rotate.integrations.notify.topic == "ops"
) "rotation notify topic not wired";
pkgs.runCommand "selfhost-oidc-rotation-eval" { } "touch $out"
