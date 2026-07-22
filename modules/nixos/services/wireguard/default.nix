{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  wg = cfg.apps.wireguard;

  # The server key must exist before whichever backend creates wg0 (systemd-networkd under networkd,
  # wireguard-<iface>.service otherwise); anchor keygen on it. Client peers are declarative (below).
  ifaceBackend =
    if config.networking.wireguard.useNetworkd then "systemd-networkd.service" else "wireguard-${wg.interface}.service";

  dataDir = "/var/lib/wireguard";
  serverKeyFile = "${dataDir}/server/private.key";
  serverPubKeyFile = "${dataDir}/server/public.key";

  enabledUsers = lib.filterAttrs (_: u: u.services.wireguard.enable) cfg.users;

  clients = lib.concatLists (
    lib.mapAttrsToList (
      _: u:
      map (d: {
        name = "${u.username}-${d.name}";
        device = d.name;
        inherit (d) ip fullAccess publicKey;
      }) u.services.wireguard.devices
    ) enabledUsers
  );

  wgEnv = {
    WG_DATA_DIR = dataDir;
    WG_INTERFACE = wg.interface;
    WG_HOMELAB_NAME = wg.name;
    WG_SERVER_ENDPOINT = "${wg.endpoint}:${toString wg.listenPort}";
    WG_CLIENT_SUBNET = wg.clientSubnet;
    WG_CLIENT_DNS = wg.dns;
    WG_SERVER_ALLOWED_IPS = lib.concatStringsSep "," (
      [ wg.clientSubnet ] ++ lib.optional wg.lanAccess.enable wg.lanAccess.subnet
    );
  };

  wgManage = pkgs.writeShellApplication {
    name = "wg-manage";
    runtimeInputs = [ pkgs.selfhost.wg-manage ];
    text = ''
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "export ${k}=\"${v}\"") wgEnv)}
      exec wg-manage-bin "$@"
    '';
  };
in
{
  imports = [ ./user.nix ];

  options.selfhost.apps.wireguard = {
    enable = lib.mkEnableOption "WireGuard VPN server (interface, keys, user/device registry, client provisioning)";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wg0";
      description = "WireGuard interface name.";
    };
    listenPort = lib.mkOption {
      type = lib.types.port;
      default = 51820;
      description = "WireGuard UDP listen port (opened in the firewall).";
    };
    exporterPort = lib.mkOption {
      type = lib.types.port;
      default = 9586;
      description = "Prometheus wireguard-exporter listen port (localhost).";
    };
    address = lib.mkOption {
      type = lib.types.str;
      description = "Server address with CIDR (e.g. 10.100.0.1/24).";
    };
    clientSubnet = lib.mkOption {
      type = lib.types.str;
      description = "Client address subnet (e.g. 10.100.0.0/24).";
    };
    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Public endpoint host/IP that clients dial.";
    };
    dns = lib.mkOption {
      type = lib.types.str;
      description = "DNS server pushed to clients.";
    };
    name = lib.mkOption {
      type = lib.types.str;
      description = "Short identity prefix for client interface/device names (e.g. 'bphenr').";
    };
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the WireGuard listen UDP port in the firewall.";
    };

    lanAccess = {
      enable = lib.mkEnableOption "opt-in nftables forwarding/NAT so clients reach the LAN (else clients reach only the server)";
      subnet = lib.mkOption {
        type = lib.types.str;
        description = "LAN subnet full-access clients may reach; added to their AllowedIPs and used as the masquerade destination. Required when lanAccess.enable.";
      };
      masquerade = lib.mkEnableOption "srcnat masquerade of client traffic into the LAN (enable only if the LAN lacks routes back to the client subnet)";
    };

    peers = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf lib.types.anything);
      readOnly = true;
      default = clients;
      defaultText = lib.literalMD "derived from `users.*.services.wireguard`";
      description = "Derived per-device peers `{ name, device, ip, fullAccess, publicKey }` for consumer firewall/routing rules.";
    };
  };

  config = lib.mkIf wg.enable (
    lib.mkMerge [
      {
        selfhost.services.wireguard = {
          meta.description = "VPN";
          port = wg.listenPort;
          ingress.enable = false;
          integrations.monitoring = {
            healthcheck = false;
            exporters.wireguard = {
              enable = true;
              listenAddress = "127.0.0.1";
              port = wg.exporterPort;
              latestHandshakeDelay = true;
            };
            scrapeConfigs = [
              {
                job_name = "wireguard";
                static_configs = [
                  {
                    targets = [ "127.0.0.1:${toString wg.exporterPort}" ];
                    labels.instance = config.networking.hostName;
                  }
                ];
              }
            ];
          };
        };

        systemd.tmpfiles.rules = [
          "d ${dataDir} 0700 root root -"
          "d ${dataDir}/server 0700 root root -"
          "d ${dataDir}/clients 0700 root root -"
        ];

        systemd.services.wireguard-keygen = {
          description = "WireGuard keygen";
          wantedBy = [ ifaceBackend ];
          before = [ ifaceBackend ];
          after = [ "systemd-tmpfiles-setup.service" ];
          serviceConfig.Type = "oneshot";
          path = [ pkgs.wireguard-tools ];
          script = ''
            if [ ! -f "${serverKeyFile}" ]; then
              echo "Generating Wireguard key..."
              wg genkey > ${serverKeyFile}
              chmod 0600 ${serverKeyFile}
              wg pubkey < ${serverKeyFile} > ${serverPubKeyFile}
            else
              echo "Wireguard key already exists."
            fi
            echo "Wireguard key ready."
          '';
        };

        # Peers are declarative: the registry's public key + tunnel IP become a [WireGuardPeer]
        # (networkd) or a scripted peer. Reconcile-safe; no runtime `wg set`. Private keys never
        # leave the server FS (see wg-manage) and pubkeys are non-secret, so config is the truth.
        networking.wireguard.interfaces.${wg.interface} = {
          ips = [ wg.address ];
          inherit (wg) listenPort;
          privateKeyFile = serverKeyFile;
          peers = map (c: {
            inherit (c) publicKey;
            allowedIPs = [ "${c.ip}/32" ];
          }) clients;
        };

        networking.firewall.allowedUDPPorts = lib.optionals wg.openFirewall [ wg.listenPort ];

        assertions =
          let
            clientsByIp = builtins.groupBy (c: c.ip) clients;
            ipCollisions = lib.filterAttrs (_: cs: builtins.length cs > 1) clientsByIp;

            maxIfNameLen = 15;
            prefix = "${wg.name}-";
            maxDeviceLen = maxIfNameLen - builtins.stringLength prefix;
            tooLong = builtins.filter (c: builtins.stringLength c.device > maxDeviceLen) clients;
          in
          [
            {
              assertion = ipCollisions == { };
              message = "WireGuard IP collision detected: ${
                lib.concatStringsSep ", " (
                  lib.mapAttrsToList (ip: cs: "${ip} -> [${lib.concatMapStringsSep ", " (c: c.name) cs}]") ipCollisions
                )
              }";
            }
            {
              assertion = tooLong == [ ];
              message = "WireGuard device name too long (max ${toString maxDeviceLen} chars with prefix '${prefix}'): ${
                lib.concatMapStringsSep ", " (c: "'${c.device}' (${toString (builtins.stringLength c.device)} chars)") tooLong
              }";
            }
          ];

        environment.systemPackages = [ wgManage ];
      }

      (lib.mkIf wg.lanAccess.enable (
        let
          fullAccessPeers = builtins.filter (c: c.fullAccess) wg.peers;

          # Govern only WireGuard clients: fullAccess devices forward to the LAN, the rest reach just
          # the server. Other forwarding (containers, bridges) is left to whatever manages it, so this
          # never has to know about podman/microvm/etc.
          forwardRules = map (c: ''iifname "${wg.interface}" ip saddr ${c.ip} accept'') fullAccessPeers ++ [
            ''iifname "${wg.interface}" drop''
          ];

          nftablesContent = ''
            chain forward {
              type filter hook forward priority 0; policy accept;
              ${lib.concatStringsSep "\n      " forwardRules}
            }
          ''
          + lib.optionalString wg.lanAccess.masquerade ''
            chain postrouting {
              type nat hook postrouting priority srcnat; policy accept;
              ip saddr ${wg.clientSubnet} ip daddr ${wg.lanAccess.subnet} masquerade
            }
          '';
        in
        {
          boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
          networking.nftables.enable = true;
          networking.nftables.tables.wireguard-access = {
            family = "inet";
            content = nftablesContent;
          };
        }
      ))
    ]
  );
}
