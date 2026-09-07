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
    dns = "10.100.0.1";
    name = "test";
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

  mkLanAccess =
    extra:
    (evalConfig {
      selfhost.apps.wireguard = server // {
        lanAccess = {
          enable = true;
          subnet = "192.168.1.0/24";
        }
        // extra;
      };
    }).boot.kernel.sysctl;
  bcastOn = mkLanAccess { broadcastForwarding = true; };
  bcastOff = mkLanAccess { };

  peerNames = lib.sort (a: b: a < b) (map (p: p.name) ok.selfhost.apps.wireguard.peers);
  collisionFires = lib.any (a: !a.assertion && lib.hasInfix "IP collision" a.message) collide.assertions;
in
assert lib.assertMsg (
  peerNames == [
    "admin-phone"
    "bob-laptop"
  ]
) "wrong peers: ${toString peerNames}";
assert lib.assertMsg collisionFires "IP-collision assertion did not fire on a duplicate";
assert lib.assertMsg (
  (bcastOn."net.ipv4.conf.all.bc_forwarding" or null) == 1 && (bcastOn."net.ipv4.conf.wg0.bc_forwarding" or null) == 1
) "broadcastForwarding did not set both bc_forwarding sysctls";
assert lib.assertMsg (
  !(bcastOff ? "net.ipv4.conf.all.bc_forwarding") && !(bcastOff ? "net.ipv4.conf.wg0.bc_forwarding")
) "bc_forwarding leaked without broadcastForwarding";
pkgs.runCommand "selfhost-wireguard-eval" { } "touch $out"
