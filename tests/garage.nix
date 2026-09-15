# Garage: the layout, buckets and imported keys come up unattended, and the imported credentials are
# the ones from runtime secrets rather than any Garage generated for itself.
#
# The layout is the interesting part: Garage stores nothing until one is applied, and applying it
# needs a version number that only Garage knows, so the reconciler has to read it back.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-garage";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ common ];

      selfhost.apps.garage = {
        enable = true;
        buckets = [ "vault" ];
      };

      selfhost.runtimeSecrets = {
        "garage-rpc-secret".regenerateIfMissing = lib.mkForce true;
        "garage-key-id-vault".regenerateIfMissing = lib.mkForce true;
        "garage-key-secret-vault".regenerateIfMissing = lib.mkForce true;
      };
    };

  testScript = ''
    machine.wait_for_unit("garage.service")
    machine.wait_for_unit("garage-configure.service")

    # Provisioned on the first try: a reconciler that misreads the staged layout version retries.
    machine.succeed("test \"$(systemctl show garage-configure.service -p NRestarts --value)\" = 0")

    # The bucket and key exist, which Garage refuses to do until a layout is applied, so this covers
    # the layout step by its only observable consequence.
    machine.succeed("garage bucket list | grep -q vault")

    # The key is the one from runtime secrets, not one Garage minted for itself.
    key_id = machine.succeed(
        "grep AWS_ACCESS_KEY_ID /run/homelab-secrets/templates/garage-vault.env | cut -d= -f2"
    ).strip()
    assert key_id.startswith("GK"), f"key id should carry Garage's GK prefix, got {key_id}"
    machine.succeed(f"garage key list | grep -q {key_id}")

    # ...and it is granted on the bucket, otherwise S3 requests would authenticate and then 403.
    machine.succeed(f"garage bucket info vault | grep -q {key_id}")
    machine.succeed("garage bucket info vault | grep -q RWO")

    # The S3 endpoint is listening and refusing unsigned requests, which is what healthcheck
    # probeModule = "http_any" asserts in production.
    machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3900/ | grep -q 403")

    # Idempotent: a second run over an applied layout and existing bucket still succeeds.
    machine.succeed("systemctl restart garage-configure.service")
    machine.succeed("garage bucket list | grep -q vault")
  '';
}
