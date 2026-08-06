# Immich: covers both consumer patterns in one boot. `admin` owns an external library (directories
# scanned in place), `family` is upload-only with no libraries at all. No OIDC provider runs here, so
# `services.immich.oidc.enable` composes to false; the OIDC wiring is configuration and is covered by
# evaluation rather than by standing up a provider.
{ pkgs, common, ... }:
let
  contract = ../modules/nixos/services/immich/api-contract.json;

  check-contract = pkgs.writeShellApplication {
    name = "immich-check-contract";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      problems=$(jq --slurpfile spec "$1" -r '
        .sends | to_entries[] | .key as $op | (.key | split(" ")) as [$m, $p]
        | ($spec[0].paths[$p][$m].requestBody.content["application/json"].schema["$ref"] // "") as $ref
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
      echo "immich request contract OK"
    '';
  };
in
pkgs.testers.runNixOSTest {
  name = "selfhost-immich";

  nodes.machine =
    { config, ... }:
    {
      imports = [ common ];

      # Immich brings up Postgres and Redis alongside the server.
      virtualisation.memorySize = 4096;
      virtualisation.diskSize = 8192;

      environment.systemPackages = [ check-contract ];

      selfhost = {
        apps.immich.enable = true;

        users.admin.services.immich = {
          enable = true;
          libraries = [
            {
              name = "admin-photos";
              importPaths = [ "/srv/photos" ];
              exclusionPatterns = [ "**/.stfolder/**" ];
            }
          ];
        };

        users.family = {
          email = "family@test.local";
          firstName = "Fam";
          lastName = "Ily";
          groups = [ config.selfhost.groups.users ];
          auth.oidc.enable = false;
          # No libraries: the upload-only pattern, with the quota that pattern needs.
          services.immich = {
            enable = true;
            quotaBytes = 1073741824;
            storageLabel = "family";
          };
        };
      };

      # Machine learning is a heavy optional subsystem and nothing here exercises it.
      services.immich.machine-learning.enable = false;

      systemd.tmpfiles.rules = [
        "d /srv/photos 0750 ${config.services.immich.user} ${config.services.immich.group} -"
      ];
    };

  testScript = ''
    import json

    machine.wait_for_unit("immich-server.service")
    machine.wait_for_unit("immich-configure.service")

    machine.succeed("curl -sf http://127.0.0.1:2283/api/spec.json -o /tmp/spec.json")
    print(machine.succeed("immich-check-contract /tmp/spec.json"))

    pw = machine.succeed("cat /var/lib/homelab-secrets/immich-admin-password").strip()
    token = json.loads(machine.succeed(
        "curl -sf -X POST http://127.0.0.1:2283/api/auth/login "
        "-H 'Content-Type: application/json' "
        f"-d '{{\"email\":\"admin@immich.local\",\"password\":\"{pw}\"}}'"
    ))["accessToken"]

    def api(path):
        return json.loads(machine.succeed(
            f"curl -sf -H 'Authorization: Bearer {token}' http://127.0.0.1:2283/api{path}"
        ))

    # Both one-time steps ran for real: posting {} to admin-onboarding would 400 on the required field.
    cfg = json.loads(machine.succeed("curl -sf http://127.0.0.1:2283/api/server/config"))
    assert cfg["isInitialized"] and cfg["isOnboarded"], cfg

    users = {u["email"]: u for u in api("/admin/users")}
    assert users["admin@test.local"]["isAdmin"] is True, users
    assert users["family@test.local"]["isAdmin"] is False, users

    # Quota and storage label are what make the upload-only pattern usable for more than one person.
    assert users["family@test.local"]["quotaSizeInBytes"] == 1073741824, users
    assert users["family@test.local"]["storageLabel"] == "family", users
    assert users["admin@test.local"]["quotaSizeInBytes"] is None, users

    # An account the framework did not declare is left alone rather than deleted or demoted.
    machine.succeed(
        "curl -sf -X POST http://127.0.0.1:2283/api/admin/users "
        f"-H 'Authorization: Bearer {token}' -H 'Content-Type: application/json' "
        "-d '{\"email\":\"stray@test.local\",\"name\":\"Stray\",\"password\":\"correcthorse\"}'"
    )

    # The external library landed on the owner that declared it; family declared none.
    libs = api("/libraries")
    assert len(libs) == 1, libs
    assert libs[0]["name"] == "admin-photos", libs
    assert libs[0]["importPaths"] == ["/srv/photos"], libs
    assert libs[0]["exclusionPatterns"] == ["**/.stfolder/**"], libs
    assert libs[0]["ownerId"] == users["admin@test.local"]["id"], libs

    # Reconcile is idempotent, and create-and-update only: the undeclared account survives.
    machine.succeed("systemctl restart immich-configure.service")
    machine.wait_for_unit("immich-configure.service")
    assert len(api("/libraries")) == 1
    assert "stray@test.local" in {u["email"] for u in api("/admin/users")}
  '';
}
