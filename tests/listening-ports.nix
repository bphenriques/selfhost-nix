# Every port the framework opens in the firewall must also be registered in `internal.listeningPorts`,
# so the collision check sees the edge and not only loopback backends. Stated as coverage rather than a
# list of expected entries: a provider that starts opening a port and forgets to register it fails here,
# which is the drift that once left traefik's 80/443, gitea's SSH, wireguard's tunnel and samba's 445
# outside the check while every loopback socket was inside it.
{ pkgs, evalConfig }:
let
  inherit (pkgs) lib;
  stub = "/run/secrets/stub";

  cfg = evalConfig {
    users.users.ada = {
      isNormalUser = true;
      uid = 4000;
    };

    selfhost = {
      # The four providers that open a firewall port, each with the toggle that does it.
      ingress = {
        traefik.enable = true;
        acme = {
          email = "a@test.local";
          dnsProvider = "cloudflare";
          credentialsEnvFile = stub;
        };
      };

      apps.gitea = {
        enable = true;
        ssh = {
          enable = true;
          openFirewall = true;
        };
      };

      apps.wireguard = {
        enable = true;
        openFirewall = true;
        address = "10.100.0.1/24";
        clientSubnet = "10.100.0.0/24";
        endpoint = "vpn.test.local";
        dns = "10.100.0.1";
        name = "test";
      };

      users.ada = {
        email = "ada@test.local";
        firstName = "Ada";
        lastName = "Lovelace";
        groups = [ "admin" ];
        auth.oidc.enable = false;
        storage.smb = {
          enable = true;
          passwordFile = stub;
        };
      };

      storage.shares.smb = {
        enable = true;
        openFirewall = true;
        shares.media = {
          path = "/srv/storage/media";
          gid = 990;
          access.users.ada = "rw";
        };
      };
    };
  };

  fw = cfg.networking.firewall;

  # Ports opened globally and per-interface, as "<proto>/<port>".
  socketsOf = f: map (p: "tcp/${toString p}") f.allowedTCPPorts ++ map (p: "udp/${toString p}") f.allowedUDPPorts;

  firewallSockets = lib.unique (socketsOf fw ++ lib.concatMap socketsOf (lib.attrValues fw.interfaces));

  registeredSockets = lib.unique (map (e: "${e.protocol}/${toString e.port}") cfg.selfhost.internal.listeningPorts);

  unregistered = lib.subtractLists registeredSockets firewallSockets;

  # The framework opens no ranges; if one appears it needs registering too, and this says so.
  ranges = fw.allowedTCPPortRanges ++ fw.allowedUDPPortRanges;
in
assert lib.assertMsg (firewallSockets != [ ]) "the fixture opened no firewall ports, so this proves nothing";
assert lib.assertMsg (unregistered == [ ])
  "Firewall-opened ports missing from selfhost.internal.listeningPorts: ${lib.concatStringsSep ", " unregistered}. Register the socket where the module opens the port, or the collision check cannot see it.";
assert lib.assertMsg (ranges == [ ])
  "The framework opened a port range, which this check does not cover: ${lib.generators.toPretty { } ranges}";
pkgs.runCommand "selfhost-listening-ports-eval" { } "touch $out"
