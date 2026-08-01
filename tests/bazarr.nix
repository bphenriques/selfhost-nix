# Bazarr end-to-end: the seed must hand Bazarr a known API key and a localhost bind before it starts, and
# the reconcile must then apply the *arr link, the language profile and the caller's freeform settings
# through Bazarr's own settings API. bazarr-configure errors on any failed call, so reaching `active`
# proves the reconcile; the API queries confirm the state landed in both config.yaml and the database.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-bazarr";

  nodes.machine = {
    imports = [ common ];

    environment.systemPackages = [
      pkgs.curl
      pkgs.jq
    ];

    systemd.tmpfiles.rules = [
      "d /mnt/media 0755 sonarr sonarr -"
      "d /mnt/media/tv 0755 sonarr sonarr -"
    ];

    selfhost.monitoring.enable = true;

    selfhost.apps.sonarr = {
      enable = true;
      rootFolders = [ { path = "/mnt/media/tv"; } ];
    };

    selfhost.apps.bazarr = {
      enable = true;
      configureAfter = [ "sonarr.service" ];
      sonarr.apiKeyFile = "/var/lib/homelab-secrets/sonarr-api-key";
      languageProfiles = [
        {
          name = "English";
          languages = [ "en" ];
          cutoff = "en";
        }
        {
          name = "Multi";
          languages = [
            "en"
            "fr"
          ];
        }
      ];
      defaultProfile = "English";
      # Stands in for provider config: a plain freeform setting the framework knows nothing about.
      settings.general.minimum_score = 92;
    };
  };

  testScript =
    { nodes, ... }:
    let
      port = toString nodes.machine.selfhost.services.bazarr.port;
      api = "http://127.0.0.1:${port}/api";
      exporterPort = toString nodes.machine.selfhost.apps.bazarr.exporterPort;
      configFile = "${nodes.machine.selfhost.apps.bazarr.dataDir}/config/config.yaml";
    in
    ''
      import json

      machine.wait_for_unit("bazarr.service")
      machine.wait_for_open_port(${port})

      # The seed is what makes the rest possible: without a known key the reconcile cannot authenticate.
      key = machine.succeed("cat /var/lib/homelab-secrets/bazarr-api-key").strip()
      machine.succeed(f"grep -q {key} ${configFile}")
      machine.succeed("grep -q '127.0.0.1' ${configFile}")
      machine.succeed(f"curl -sf -H 'X-API-KEY: {key}' ${api}/system/status >/dev/null")

      machine.wait_for_unit("bazarr-configure.service")

      # Language profiles live in the database, not config.yaml — this is the half a config file cannot do,
      # and with no profile Bazarr fetches nothing at all.
      profiles = json.loads(machine.succeed(f"curl -sf -H 'X-API-KEY: {key}' ${api}/system/languages/profiles"))
      by_name = {p["name"]: p for p in profiles}
      assert set(by_name) == {"English", "Multi"}, f"unexpected profiles: {list(by_name)}"
      assert [i["language"] for i in by_name["English"]["items"]] == ["en"]
      assert [i["language"] for i in by_name["Multi"]["items"]] == ["en", "fr"]

      # cutoff refers to an item id, so a wrong mapping silently changes when Bazarr stops searching.
      english = by_name["English"]
      assert english["cutoff"] == english["items"][0]["id"], f"cutoff not mapped to the item id: {english}"
      assert by_name["Multi"]["cutoff"] is None, "profile without a cutoff should keep searching"

      # ...and the other half: settings that do land in config.yaml, including the freeform passthrough.
      settings = json.loads(machine.succeed(f"curl -sf -H 'X-API-KEY: {key}' ${api}/system/settings"))
      assert settings["general"]["use_sonarr"] is True, "sonarr link not enabled"
      assert settings["sonarr"]["port"] == ${toString nodes.machine.selfhost.services.sonarr.port}
      assert settings["general"]["minimum_score"] == 92, "freeform setting not applied"
      assert settings["general"]["serie_default_enabled"] is True, "default profile not enabled"
      assert settings["general"]["serie_default_profile"] == english["profileId"]

      # Sonarr's key must have been read from disk at reconcile time, never baked into the store.
      sonarr_key = machine.succeed("cat /var/lib/homelab-secrets/sonarr-api-key").strip()
      assert settings["sonarr"]["apikey"] == sonarr_key, "sonarr api key not wired through"

      # Idempotent: re-running must not duplicate profiles or renumber them (media points at profileId).
      machine.systemctl("restart bazarr-configure.service")
      machine.wait_for_unit("bazarr-configure.service")
      again = json.loads(machine.succeed(f"curl -sf -H 'X-API-KEY: {key}' ${api}/system/languages/profiles"))
      assert len(again) == 2, f"expected 2 profiles after re-reconcile, got {len(again)}"
      assert {p["name"]: p["profileId"] for p in again} == {p["name"]: p["profileId"] for p in profiles}, \
          "profile ids changed on re-reconcile"

      machine.wait_for_unit("prometheus-exportarr-bazarr-exporter.service")
      machine.wait_until_succeeds("curl -sf http://127.0.0.1:${exporterPort}/metrics | grep -q '^bazarr_'", timeout=60)
    '';
}
