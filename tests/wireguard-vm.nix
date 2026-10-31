# apps.wireguard peer lifecycle: wg-manage owns the peer file and applies it live, and the boot unit
# restores it when the interface reappears. Both backends: scripted (`wg set`) and networkd (a netdev
# drop-in, so a networkd restart re-applies the peers instead of wiping them). The eval test covers the
# ruleset; this covers the state.
{ pkgs, common, ... }:
let
  wireguard = {
    imports = [ common ];
    selfhost.apps.wireguard = {
      enable = true;
      address = "10.100.0.1/24";
      clientSubnet = "10.100.0.0/24";
      fullAccessSubnet = "10.100.0.0/28";
      endpoint = "vpn.test.local";
      dns = "1.1.1.1";
    };
  };
in
pkgs.testers.runNixOSTest {
  name = "selfhost-wireguard";

  nodes.machine = wireguard;
  nodes.networkd = {
    imports = [ wireguard ];
    networking.useNetworkd = true;
  };

  testScript = ''
    machine.wait_for_unit("wireguard-apply-peers.service")
    machine.succeed("wg show wg0 >/dev/null")

    # Allocation is the tier: the first restricted address falls outside the /28, the first full-access
    # one inside it, and neither collides with the server's own 10.100.0.1.
    machine.succeed("wg-manage add relative >/dev/null")
    machine.succeed("wg-manage add mine --full-access >/dev/null")
    peers = machine.succeed("wg-manage status")
    assert "10.100.0.16" in peers and "10.100.0.2" in peers, peers
    assert "server" in peers and "lan" in peers, peers

    # Live immediately, with the key pinned to that one address.
    machine.succeed("wg show wg0 allowed-ips | grep -q '10.100.0.16/32'")
    machine.succeed("wg show wg0 allowed-ips | grep -q '10.100.0.2/32'")

    # A name is the handle, so it has to be unique and well-formed.
    machine.fail("wg-manage add relative")
    machine.fail("wg-manage add 'Not A Name'")
    machine.fail("wg-manage remove nobody")

    # The file survives the interface. Nothing restarts the unit by hand: the device reappearing is
    # what pulls it in, which is the ordering the old target-wanted version got wrong.
    machine.succeed("ip link del wg0")
    machine.succeed("systemctl restart wireguard-wg0.service")
    machine.wait_until_succeeds("wg show wg0 allowed-ips | grep -q '10.100.0.16/32'", timeout=30)
    machine.succeed("wg show wg0 allowed-ips | grep -q '10.100.0.2/32'")

    # apply is also the only thing that drops a peer nobody registered.
    stray = machine.succeed("wg genkey | wg pubkey").strip()
    machine.succeed(f"wg set wg0 peer {stray} allowed-ips 10.100.0.99/32")
    assert stray in machine.succeed("wg-manage status 2>&1")
    machine.succeed("wg-manage apply")
    machine.fail(f"wg show wg0 peers | grep -q {stray}")

    # remove forgets before it cuts, so nothing comes back on the next apply.
    machine.succeed("wg-manage remove relative")
    machine.succeed("wg-manage apply")
    machine.fail("wg show wg0 allowed-ips | grep -q '10.100.0.16/32'")
    machine.succeed("wg show wg0 allowed-ips | grep -q '10.100.0.2/32'")

    # An absent peer file means leave the interface alone, not wipe it.
    machine.succeed("mv /var/lib/wireguard/peers.json /var/lib/wireguard/peers.json.bak")
    machine.succeed("wg-manage apply")
    machine.succeed("wg show wg0 allowed-ips | grep -q '10.100.0.2/32'")

    # networkd re-applies the netdev whenever it restarts, which replaced the peer list with none until
    # the peers moved into a drop-in on it.
    networkd.wait_for_unit("wireguard-apply-peers.service")
    networkd.succeed("wg-manage add mine --full-access >/dev/null")
    networkd.wait_until_succeeds("wg show wg0 allowed-ips | grep -q '10.100.0.2/32'", timeout=30)

    # A stray peer gone after the restart proves networkd rebuilt the list, so the registered one
    # surviving came from the drop-in rather than being left alone.
    stray = networkd.succeed("wg genkey | wg pubkey").strip()
    networkd.succeed(f"wg set wg0 peer {stray} allowed-ips 10.100.0.99/32")
    networkd.succeed("systemctl restart systemd-networkd")
    networkd.wait_until_fails(f"wg show wg0 peers | grep -q {stray}", timeout=30)
    networkd.succeed("wg show wg0 allowed-ips | grep -q '10.100.0.2/32'")

    networkd.succeed("wg-manage remove mine")
    networkd.wait_until_fails("wg show wg0 allowed-ips | grep -q '10.100.0.2/32'", timeout=30)
  '';
}
