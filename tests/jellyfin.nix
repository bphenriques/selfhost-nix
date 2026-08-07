# Jellyfin: the wizard runs unattended, a library lands on its directory, and an account gets its policy.
# The branding assertion is a regression test: the reconcile must merge onto what the server holds, since
# an SSO plugin owns LoginDisclaimer and an earlier version of this script replaced the whole object.
{ pkgs, common, ... }:
let
  contract = ../modules/nixos/services/jellyfin/api-contract.json;

  check-contract = pkgs.writeShellApplication {
    name = "jellyfin-check-contract";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      problems=$(jq --slurpfile spec "$1" -r '
        .sends | to_entries[] | .key as $op | (.key | split(" ")) as [$m, $p]
        | ($spec[0].paths[$p][$m].requestBody.content["application/json"].schema) as $s
        | (($s["$ref"] // $s.allOf[0]["$ref"]) // "") as $ref
        | if $ref == "" then "\($op): no JSON request body in spec"
          else ($ref | split("/") | last) as $dto
          | (.value - ($spec[0].components.schemas[$dto].properties | keys)) as $unknown
          | if ($unknown | length) > 0
            then "\($op): absent from \($dto): \($unknown | join(", "))"
            else empty end
          end' ${contract})

      if [ -n "$problems" ]; then
        echo "$problems"
        exit 1
      fi
      echo "jellyfin request contract OK"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "selfhost-jellyfin";

  nodes.machine =
    { config, ... }:
    {
      imports = [ common ];

      virtualisation.memorySize = 2048;
      # Jellyfin refuses to start with under 2 GiB free in its data directory.
      virtualisation.diskSize = 8192;

      environment.systemPackages = [ check-contract ];

      selfhost = {
        apps.jellyfin = {
          enable = true;
          serverName = "Selfhost";
          libraries = [
            {
              name = "Movies";
              collectionType = "movies";
              locations = [ "/srv/movies" ];
              options.EnableRealtimeMonitor = false;
            }
          ];
          branding.CustomCss = "/* selfhost */";
          encoding.EncodingThreadCount = 2;
        };

        users.admin.services.jellyfin = {
          enable = true;
          policy.EnableSubtitleManagement = true;
        };
      };

      systemd.tmpfiles.rules = [
        "d /srv/movies 0755 ${config.services.jellyfin.user} ${config.services.jellyfin.group} -"
      ];
    };

  testScript = ''
    import json

    machine.wait_for_unit("jellyfin.service")
    machine.wait_for_unit("jellyfin-configure.service")

    machine.succeed("curl -sf http://127.0.0.1:8096/api-docs/openapi.json -o /tmp/spec.json")
    print(machine.succeed("jellyfin-check-contract /tmp/spec.json"))

    # The wizard ran unattended; nothing here clicked through it.
    info = json.loads(machine.succeed("curl -sf http://127.0.0.1:8096/System/Info/Public"))
    assert info["StartupWizardCompleted"] is True, info
    assert info["ServerName"] == "Selfhost", info

    pw = machine.succeed("cat /var/lib/homelab-secrets/jellyfin-admin-password").strip()
    client = 'MediaBrowser Client="test", Device="test", DeviceId="test", Version="1"'
    token = json.loads(machine.succeed(
        "curl -sf -X POST http://127.0.0.1:8096/Users/AuthenticateByName "
        "-H 'Content-Type: application/json' "
        f"-H 'Authorization: {client}' "
        f"-d '{{\"Username\":\"admin\",\"Pw\":\"{pw}\"}}'"
    ))["AccessToken"]
    auth = f"-H 'Authorization: MediaBrowser Token=\"{token}\"'"

    def api(path):
        return json.loads(machine.succeed(f"curl -sf {auth} http://127.0.0.1:8096{path}"))

    libs = {lib["Name"]: lib for lib in api("/Library/VirtualFolders")}
    assert "Movies" in libs, libs
    assert libs["Movies"]["Locations"] == ["/srv/movies"], libs
    assert libs["Movies"]["LibraryOptions"]["EnableRealtimeMonitor"] is False, libs

    assert api("/System/Configuration/encoding")["EncodingThreadCount"] == 2

    users = {u["Name"]: u for u in api("/Users")}
    assert "admin" in users, users
    assert users["admin"]["Policy"]["EnableSubtitleManagement"] is True, users

    # An SSO plugin owns LoginDisclaimer. Write one, then reconcile again: the configured CustomCss must
    # still be applied and the disclaimer must survive.
    branding = api("/Branding/Configuration")
    branding["LoginDisclaimer"] = "<a>Sign in with Pocket-ID</a>"
    machine.succeed(
        "curl -sf -X POST http://127.0.0.1:8096/System/Configuration/Branding "
        f"{auth} -H 'Content-Type: application/json' -d {json.dumps(json.dumps(branding))}"
    )

    machine.succeed("systemctl restart jellyfin-configure.service")
    machine.wait_for_unit("jellyfin-configure.service")

    after = api("/Branding/Configuration")
    assert after["LoginDisclaimer"] == "<a>Sign in with Pocket-ID</a>", after
    assert after["CustomCss"] == "/* selfhost */", after

    # Reconcile stays create-and-update only.
    assert len(api("/Library/VirtualFolders")) == 1
  '';
}
