# apps.wireguard (eval-only): peers derive from users' devices, and the IP-collision assertion fires on a
# duplicate. No VM — the value is the pure derivation + assertion, not the kernel interface.
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
  mkUser = groups: devices: {
    inherit groups;
    email = "u@test.local";
    firstName = "U";
    lastName = "Ser";
    auth.oidc.enable = false;
    services.wireguard = {
      enable = true;
      inherit devices;
    };
  };

  ok = evalConfig {
    selfhost = {
      apps.wireguard = server;
      users.admin =
        mkUser
          [ "admin" ]
          [
            {
              name = "phone";
              ip = "10.100.0.10";
              publicKey = "AdminPhonePublicKeyAAAAAAAAAAAAAAAAAAAAAAAA=";
            }
          ];
      users.bob =
        mkUser
          [ "users" ]
          [
            {
              name = "laptop";
              ip = "10.100.0.20";
              publicKey = "BobLaptopPublicKeyBBBBBBBBBBBBBBBBBBBBBBBBB=";
            }
          ];
    };
  };
  collide = evalConfig {
    selfhost = {
      apps.wireguard = server;
      users.admin =
        mkUser
          [ "admin" ]
          [
            {
              name = "phone";
              ip = "10.100.0.10";
              publicKey = "CollidePhonePublicKeyCCCCCCCCCCCCCCCCCCCCCC=";
            }
            {
              name = "laptop";
              ip = "10.100.0.10";
              publicKey = "CollideLaptopPublicKeyDDDDDDDDDDDDDDDDDDDDD=";
            }
          ];
    };
  };
  reusedKey = evalConfig {
    selfhost = {
      apps.wireguard = server;
      users.admin =
        mkUser
          [ "admin" ]
          [
            {
              name = "phone";
              ip = "10.100.0.10";
              publicKey = "SharedPublicKeyEEEEEEEEEEEEEEEEEEEEEEEEEEEE=";
            }
            {
              name = "laptop";
              ip = "10.100.0.11";
              publicKey = "SharedPublicKeyEEEEEEEEEEEEEEEEEEEEEEEEEEEE=";
            }
          ];
    };
  };

  mkLanAccess =
    extra:
    evalConfig {
      selfhost = {
        apps.wireguard = server // {
          fullAccessSubnet = "10.100.0.0/28";
          lanAccess = {
            enable = true;
            subnet = "192.168.1.0/24";
          }
          // extra;
        };
        users.admin =
          mkUser
            [ "admin" ]
            [
              {
                name = "phone";
                ip = "10.100.0.10";
                publicKey = "AdminPhonePublicKeyAAAAAAAAAAAAAAAAAAAAAAAA=";
              }
            ];
      };
    };
  wolOn = mkLanAccess { wakeOnLan = true; };
  wolOff = mkLanAccess { };
  wolRuleset = wolOn.networking.nftables.tables.wireguard-access.content;
  # Everything before the peer's blanket accept, so the broadcast drop must be ordered ahead of it.
  beforePeerAccept = lib.head (lib.splitString "ip saddr 10.100.0.0/28 accept" wolRuleset);

  # The netdev peers are what the server actually routes, and the /32 is what pins a key to one address.
  peerRoutes = lib.sort (a: b: a < b) (map (p: lib.head p.allowedIPs) ok.networking.wireguard.interfaces.wg0.peers);
  collisionFires = lib.any (a: !a.assertion && lib.hasInfix "10.100.0.10 -> [admin-phone, admin-laptop]" a.message) collide.assertions;
  keyReuseFires = lib.any (a: !a.assertion && lib.hasInfix "public key reused" a.message) reusedKey.assertions;
in
assert lib.assertMsg (
  peerRoutes == [
    "10.100.0.10/32"
    "10.100.0.20/32"
  ]
) "wrong peer routes: ${toString peerRoutes}";
assert lib.assertMsg collisionFires "IP-collision assertion did not fire on a duplicate";
assert lib.assertMsg keyReuseFires "public-key-reuse assertion did not fire on a shared key";
assert lib.assertMsg (
  (wolOn.boot.kernel.sysctl."net.ipv4.conf.all.bc_forwarding" or null) == 1
  && (wolOn.boot.kernel.sysctl."net.ipv4.conf.wg0.bc_forwarding" or null) == 1
) "wakeOnLan did not set both bc_forwarding sysctls";
assert lib.assertMsg (
  !(wolOff.boot.kernel.sysctl ? "net.ipv4.conf.all.bc_forwarding")
  && !(wolOff.boot.kernel.sysctl ? "net.ipv4.conf.wg0.bc_forwarding")
  && !(lib.hasInfix "fib daddr type broadcast" wolOff.networking.nftables.tables.wireguard-access.content)
) "wakeOnLan leaked while disabled";
assert lib.assertMsg
  (lib.hasInfix "ip saddr 10.100.0.0/28 fib daddr type broadcast udp dport { 7, 9 } accept" wolRuleset)
  "wakeOnLan did not scope the accept to full-access peers and the magic-packet ports";
assert lib.assertMsg (lib.hasInfix "fib daddr type broadcast drop" beforePeerAccept)
  "every other directed broadcast is not dropped ahead of the peer's blanket accept";
pkgs.runCommand "selfhost-wireguard-eval" { } "touch $out"
