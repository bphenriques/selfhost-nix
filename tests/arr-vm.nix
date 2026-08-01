# Radarr end-to-end: the generic reconcile must apply a root folder, a download client, a delay profile and
# the ntfy connection against a real Radarr. radarr-configure is a RemainAfterExit oneshot that errors on
# any failed API call, so reaching `active` already proves the whole reconcile; the API queries then confirm
# the resources landed. Radarr exercises the shared media-arr builder (sonarr is identical); prowlarr is
# wiring-only and covered by the eval test.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-arr";

  nodes.machine = {
    imports = [ common ];

    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];

    # Radarr rejects a root folder whose path is absent, so arrange it (as the service user) first.
    systemd.tmpfiles.rules = [
      "d /mnt/media 0755 radarr radarr -"
      "d /mnt/media/movies 0755 radarr radarr -"
    ];

    # A real download client: Radarr connection-tests it on save, so the reconcile must reach a live one.
    services.transmission = {
      enable = true;
      settings = {
        rpc-bind-address = "127.0.0.1";
        rpc-port = 9091;
        rpc-authentication-required = false;
        rpc-host-whitelist-enabled = false;
        rpc-whitelist-enabled = false;
      };
    };

    # ntfy is what makes the reconcile emit a notification connection; nothing is actually sent.
    selfhost.notify.ntfy.enable = true;
    selfhost.notify.topics.media.public = false;
    selfhost.services.radarr.integrations.notify.topic = "media";

    selfhost.monitoring.enable = true;

    selfhost.apps.radarr = {
      enable = true;
      configureAfter = [ "transmission.service" ];
      # "Any" is a built-in Radarr profile — exercises create-with-default-profile (root folders are
      # immutable, so this only applies at creation).
      rootFolders = [
        {
          path = "/mnt/media/movies";
          defaultQualityProfile = "Any";
        }
      ];
      downloadClients = [
        {
          name = "Transmission";
          implementation = "Transmission";
          protocol = "torrent";
          fields = {
            host = "127.0.0.1";
            port = 9091;
            urlBase = "/transmission/";
            movieCategory = "radarr";
          };
        }
      ];
      delayProfile.preferredProtocol = "torrent";
    };
  };

  testScript =
    { nodes, ... }:
    let
      port = toString nodes.machine.selfhost.services.radarr.port;
      api = "http://127.0.0.1:${port}/api/v3";
      exporterPort = toString nodes.machine.selfhost.apps.radarr.exporterPort;
    in
    ''
      import json
      import shlex

      machine.wait_for_unit("radarr.service")

      # Reaching active means every reconcile call (root folder, download client, delay profile) succeeded —
      # which also proves the generated API key and the *arr schema-fill path work end to end.
      machine.wait_for_unit("radarr-configure.service")

      key = machine.succeed("cat /var/lib/homelab-secrets/radarr-api-key").strip()

      # Confirm the resources actually landed (count entries, not string occurrences). The reconcile reaching
      # active already proves root folders are create-or-leave (no 405 from the removed update path); the
      # default profile is best-effort (it may still be seeding), so assert presence, not the profile id.
      machine.succeed(f"curl -sf -H 'X-Api-Key: {key}' ${api}/rootfolder | jq -e --arg p /mnt/media/movies '.[] | select(.path==$p)' >/dev/null")
      machine.succeed(f"curl -sf -H 'X-Api-Key: {key}' ${api}/downloadclient | jq -e --arg n Transmission '.[] | select(.name==$n)' >/dev/null")

      # The failure-visibility flags: a dead root folder or unreachable client raises an *arr health check,
      # and without these it is never delivered anywhere.
      machine.succeed(f"curl -sf -H 'X-Api-Key: {key}' ${api}/notification | jq -e '.[] | select(.name==\"ntfy\") | select(.onHealthIssue and .onHealthRestored and .includeHealthWarnings and .onManualInteractionRequired)' >/dev/null")

      # Drift correction: the connection used to be created once and never revisited, so flag changes never
      # reached a host that already had it. Turn a flag off behind the reconcile's back and re-run.
      notification = json.loads(machine.succeed(f"curl -sf -H 'X-Api-Key: {key}' ${api}/notification | jq -c '.[] | select(.name==\"ntfy\")'"))
      notification["onHealthIssue"] = False
      machine.succeed(
          "curl -sf -X PUT -H 'X-Api-Key: {}' -H 'Content-Type: application/json' -d {} {}/notification/{}".format(
              key, shlex.quote(json.dumps(notification)), "${api}", notification["id"]
          )
      )

      # Idempotent: a second reconcile updates in place — still exactly one client, no duplicates or errors.
      machine.systemctl("restart radarr-configure.service")
      machine.wait_for_unit("radarr-configure.service")
      count = machine.succeed(f"curl -sf -H 'X-Api-Key: {key}' ${api}/downloadclient | jq --arg n Transmission '[.[] | select(.name==$n)] | length'").strip()
      assert count == "1", f"expected exactly one Transmission client after re-reconcile, got {count}"

      # ...and the notification is repaired rather than skipped, still without duplicating.
      machine.succeed(f"curl -sf -H 'X-Api-Key: {key}' ${api}/notification | jq -e '.[] | select(.name==\"ntfy\") | select(.onHealthIssue)' >/dev/null")
      ntfy_count = machine.succeed(f"curl -sf -H 'X-Api-Key: {key}' ${api}/notification | jq '[.[] | select(.name==\"ntfy\")] | length'").strip()
      assert ntfy_count == "1", f"expected exactly one ntfy connection after re-reconcile, got {ntfy_count}"

      # exportarr must actually authenticate against Radarr, not merely listen: system_health_issues only
      # appears once the health collector has talked to the API with the generated key.
      machine.wait_for_unit("prometheus-exportarr-radarr-exporter.service")
      machine.wait_for_open_port(${exporterPort})
      machine.wait_until_succeeds("curl -sf http://127.0.0.1:${exporterPort}/metrics | grep -q '^radarr_system_health_issues'", timeout=60)

      # Every collector must have completed. exportarr degrades rather than failing the scrape, so a broken
      # one shows up only here — the alert rules would otherwise sit on metrics that are silently absent.
      # (queue_total has no series with an empty queue, which is why presence is the wrong assertion.)
      metrics = machine.succeed("curl -sf http://127.0.0.1:${exporterPort}/metrics")
      errored = [
          line
          for line in metrics.splitlines()
          if "collector_error" in line and not line.startswith("#") and not line.endswith(" 0")
      ]
      assert not errored, f"exportarr collectors reporting errors: {errored}"
    '';
}
