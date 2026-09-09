# A template's consumer must see a *substituted* config the first time it starts, not merely after a
# later rebuild. The VM boots once, so this is first boot by construction.
#
# Guards the plain-template path specifically: it is the one whose rendering can be reordered without
# anything failing loudly, because a missing substitution reaches the service as a config value rather
# than as an error. The OIDC path is covered end-to-end by vm-forwardauth, where tinyauth cannot start
# at all without a real client id.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-runtime-templates";

  nodes.machine =
    { config, ... }:
    {
      imports = [ common ];

      selfhost = {
        runtimeSecrets.probe-secret.restartUnits = [ "probe-consumer.service" ];

        runtimeTemplates."probe.env" = {
          content = "PROBE_VALUE=${config.selfhost.runtimePlaceholder.probe-secret}\n";
          restartUnits = [ "probe-consumer.service" ];
        };
      };

      # Reads the rendered template the way a real service does, and records what it actually received.
      systemd.services.probe-consumer = {
        description = "Record the template value this unit was started with";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = config.selfhost.runtimeTemplates."probe.env".path;
        };
        script = ''printf '%s' "$PROBE_VALUE" > /run/probe-observed'';
      };
    };

  testScript = ''
    # If the template never rendered, EnvironmentFile is missing and this never comes up.
    machine.wait_for_unit("probe-consumer.service")

    observed = machine.succeed("cat /run/probe-observed").strip()
    secret = machine.succeed("cat /var/lib/homelab-secrets/probe-secret").strip()

    assert "PLACEHOLDER" not in observed, f"consumer started with an unsubstituted placeholder: {observed}"
    assert observed == secret, f"consumer saw {observed!r}, secret file holds {secret!r}"
    assert secret != "", "the secret was never generated"

    # The rendered file itself carries no leftovers.
    machine.fail("grep -q PLACEHOLDER /run/homelab-secrets/templates/probe.env")

    # And the value never reached the world-readable store.
    machine.fail(f"grep -rqF -- '{secret}' /nix/store")
  '';
}
