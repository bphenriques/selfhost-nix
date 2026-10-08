# coturn: the password is generated at boot and has to reach two places that must agree, the relay's own
# runtime config and whatever advertises the relay. RomM's netplay is that consumer here, which also
# covers a `settings` body rendered at runtime instead of linked from the store.
{ pkgs, common, ... }:
pkgs.testers.runNixOSTest {
  name = "selfhost-coturn";

  nodes.machine = {
    imports = [ common ];

    virtualisation.memorySize = 2048;

    selfhost.apps = {
      coturn = {
        enable = true;
        advertisedAddresses = [ "192.168.1.10" ];
        allowedPeerRanges = [ "192.168.1.0-192.168.1.255" ];
      };
      romm.enable = true;
    };
  };

  testScript = ''
    machine.wait_for_unit("coturn.service")
    machine.wait_for_unit("romm.service")
    machine.wait_for_open_port(8095)

    machine.succeed("ss -ulnH 'sport = :3478' | grep 3478")

    password = machine.succeed("cat /var/lib/homelab-secrets/coturn-romm").strip()
    turnserver = machine.succeed("cat /run/coturn/turnserver.cfg")
    assert f"user=romm:{password}" in turnserver, turnserver                      # relay side
    assert "denied-peer-ip=0.0.0.0-255.255.255.255" in turnserver, turnserver     # …relaying nowhere
    assert "allowed-peer-ip=192.168.1.0-192.168.1.255" in turnserver, turnserver  # …except the LAN

    config_yml = machine.succeed("cat /var/lib/romm/config/config.yml")
    assert password in config_yml, config_yml                                     # client side, same value
    machine.succeed(f"test -z \"$(grep -rl {password} /nix/store/*turnserver.conf)\"")           # never the store
    machine.succeed("readlink /var/lib/romm/config/config.yml | grep -q '^/run/'")              # …so this one renders

    cfg = machine.succeed("curl -fsS http://127.0.0.1:8095/api/config")
    assert '"EJS_NETPLAY_ENABLED":true' in cfg, cfg                               # …and RomM parsed it
  '';
}
