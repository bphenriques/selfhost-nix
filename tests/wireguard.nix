# apps.wireguard (eval-only): the ruleset is a function of the address plan alone, since peers are
# runtime state. No VM, because the value is the pure derivation rather than the kernel interface.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;

  server = {
    enable = true;
    address = "10.100.0.1/24";
    clientSubnet = "10.100.0.0/24";
    endpoint = "vpn.test.local";
    dns = "1.1.1.1";
  };

  mkWireguard =
    extra:
    (evalConfig { selfhost.apps.wireguard = server // extra; })
    .networking.nftables.tables.wireguard-access.content;

  restrictedOnly = mkWireguard { };
  tiered = mkWireguard {
    fullAccessSubnet = "10.100.0.0/28";
    lanAccess = {
      enable = true;
      subnet = "192.168.1.0/24";
      wakeOnLan = true;
    };
  };
  # Everything ahead of the full-access accept, so the broadcast drop must be ordered before it.
  beforeFullAccept = lib.head (lib.splitString "ip saddr 10.100.0.0/28 accept" tiered);
in
assert lib.assertMsg (lib.hasInfix "iifname \"wg0\" ct state new tcp dport { 80, 443 } accept" restrictedOnly)
  "restricted peers do not reach the default ports";
assert lib.assertMsg (lib.hasInfix "iifname \"wg0\" ct state new drop" restrictedOnly)
  "the chain does not end in a deny";
assert lib.assertMsg (!(lib.hasInfix "ip saddr" restrictedOnly))
  "a null fullAccessSubnet still carved out an exemption";
assert lib.assertMsg (lib.hasInfix "iifname \"wg0\" ip saddr 10.100.0.0/28 ct state new accept" tiered)
  "the full-access block is not exempted from the restriction";
assert lib.assertMsg
  (lib.hasInfix "ip saddr 10.100.0.0/28 fib daddr type broadcast udp dport { 7, 9 } accept" tiered)
  "wakeOnLan is not scoped to the full-access block and the magic-packet ports";
assert lib.assertMsg (lib.hasInfix "fib daddr type broadcast drop" beforeFullAccept)
  "every other directed broadcast is not dropped ahead of the blanket accept";
pkgs.runCommand "selfhost-wireguard-eval" { } "touch $out"
