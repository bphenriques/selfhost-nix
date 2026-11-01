{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  wg = cfg.apps.wireguard;

  # The server key must exist before whichever backend creates wg0, so keygen anchors on it.
  ifaceBackend =
    if config.networking.wireguard.useNetworkd then "systemd-networkd.service" else "wireguard-${wg.interface}.service";

  dataDir = "/var/lib/wireguard";
  serverKeyFile = "${dataDir}/server/private.key";
  serverPubKeyFile = "${dataDir}/server/public.key";
  peersFile = "${dataDir}/peers.json";

  # Under networkd the peers are a runtime drop-in on its netdev, named as nixpkgs names it.
  useNetworkd = config.networking.wireguard.useNetworkd;
  netdevName = "40-${wg.interface}";
  peersDropInDir = "/run/systemd/network/${netdevName}.netdev.d";

  # Ahead of nixos-fw, new connections only. The v6 drop matters: `ip saddr` never matches v6, which would fall through.
  restrictChain =
    let
      accept =
        proto: ports:
        lib.optional (ports != [ ])
          ''iifname "${wg.interface}" ct state new ${proto} dport { ${lib.concatMapStringsSep ", " toString ports} } accept'';
      rules = [
        ''iifname "${wg.interface}" meta nfproto ipv6 ct state new drop''
      ]
      ++ lib.optional (
        wg.fullAccessSubnet != null
      ) ''iifname "${wg.interface}" ip saddr ${wg.fullAccessSubnet} ct state new accept''
      ++ accept "tcp" wg.restrictedPeers.tcpPorts
      ++ accept "udp" wg.restrictedPeers.udpPorts
      ++ [ ''iifname "${wg.interface}" ct state new drop'' ];
    in
    ''
      chain input {
        type filter hook input priority filter - 1; policy accept;
        ${lib.concatStringsSep "\n  " rules}
      }
    '';

  # WoL is the one directed broadcast let through (a powered-off host answers no ARP), from full-access clients only.
  wolRules = lib.optionals (wg.lanAccess.wakeOnLan && wg.fullAccessSubnet != null) [
    ''iifname "${wg.interface}" ip saddr ${wg.fullAccessSubnet} fib daddr type broadcast udp dport { 7, 9 } accept comment "Wake-on-LAN"''
    ''iifname "${wg.interface}" fib daddr type broadcast drop''
  ];

  # Governs WireGuard clients only, so other forwarding (containers, bridges) is left alone.
  forwardRules =
    wolRules
    ++ lib.optional (wg.fullAccessSubnet != null) ''iifname "${wg.interface}" ip saddr ${wg.fullAccessSubnet} accept''
    ++ [ ''iifname "${wg.interface}" drop'' ];

  lanChains = lib.optionalString wg.lanAccess.enable (
    ''
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
    ''
  );

  # AllowedIPs is the client routing table, so a restricted device routes only the server, not a LAN clashing with its own.
  allowedIPsFull = [ wg.clientSubnet ] ++ lib.optional wg.lanAccess.enable wg.lanAccess.subnet;
  allowedIPsRestricted =
    if wg.lanAccess.enable && wg.lanAccess.serverAddress != null then
      [
        wg.clientSubnet
        "${wg.lanAccess.serverAddress}/32"
      ]
    else
      allowedIPsFull;

  # Outside `clientSubnet`, the chain and `add --full-access` fail closed silently, so catch it at eval.
  ipToInt = s: lib.foldl' (acc: o: acc * 256 + lib.toInt o) 0 (lib.splitString "." s);
  netMask = prefix: 4294967296 - lib.foldl' (acc: _: acc * 2) 1 (lib.range 1 (32 - prefix));
  within =
    inner: outer:
    let
      i = lib.splitString "/" inner;
      o = lib.splitString "/" outer;
      outerPrefix = lib.toInt (lib.elemAt o 1);
      mask = netMask outerPrefix;
    in
    lib.toInt (lib.elemAt i 1) >= outerPrefix
    && builtins.bitAnd (ipToInt (lib.head i)) mask == builtins.bitAnd (ipToInt (lib.head o)) mask;

  # One generated config, so allocation, policy and status resolve a device's tier the way the chain does.
  manageConfigFile = pkgs.writeText "wg-manage-config.json" (
    builtins.toJSON {
      inherit (wg)
        interface
        address
        clientSubnet
        fullAccessSubnet
        dns
        ;
      serverPublicKeyFile = serverPubKeyFile;
      endpoint = "${wg.endpoint}:${toString wg.listenPort}";
      allowedIPs = {
        full = lib.concatStringsSep "," allowedIPsFull;
        restricted = lib.concatStringsSep "," allowedIPsRestricted;
      };
      inherit peersFile;
      peersDropIn = if useNetworkd then "${peersDropInDir}/peers.conf" else null;
    }
  );

  wgManage = pkgs.writeShellApplication {
    name = "wg-manage";
    runtimeInputs = [
      pkgs.selfhost.wg-manage
      config.systemd.package
    ];
    text = ''
      export WG_CONFIG_FILE=${manageConfigFile}
      exec wg-manage-bin "$@"
    '';
  };
in
{
  options.selfhost.apps.wireguard = {
    enable = lib.mkEnableOption "WireGuard VPN server (interface, server keys, and runtime peer provisioning via wg-manage)";

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
    fullAccessSubnet = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.100.0.0/28";
      description = "Block within `clientSubnet` whose devices skip `restrictedPeers` and, with `lanAccess.enable`, reach the LAN. Every other client address is restricted, so a device's tier is its address. Null grants full access to nobody.";
    };
    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Public endpoint host/IP that clients dial.";
    };
    dns = lib.mkOption {
      type = lib.types.str;
      example = "1.1.1.1";
      description = "DNS server pushed to clients. Naming this host needs `restrictedPeers.udpPorts = [ 53 ]`.";
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
      serverAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "192.168.1.10";
        description = "This host's own address on `subnet`. Restricted devices route just this instead of the whole subnet, so a client whose home network overlaps it keeps its local devices. Null leaves them routing the whole subnet.";
      };

      masquerade = lib.mkEnableOption "srcnat masquerade of client traffic into the LAN (enable only if the LAN lacks routes back to the client subnet)";
      wakeOnLan = lib.mkEnableOption "forwarding Wake-on-LAN magic packets (UDP 7 and 9) from full-access clients to the LAN broadcast address; every other directed broadcast stays in the tunnel";
    };

    # Counterpart of `lanAccess`: what a restricted device reaches on this host.
    restrictedPeers = {
      tcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [
          80
          443
        ];
        description = "TCP ports on this host a device outside `fullAccessSubnet` may reach. Everything else another service opened on the tunnel interface is dropped for it. Empty allows none.";
      };

      udpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        example = [ 53 ];
        description = "UDP ports on this host a device outside `fullAccessSubnet` may reach. Empty allows none, which is why `dns` normally names a resolver these devices reach without the server. Open 53 here instead if the resolver is this host.";
      };
    };
  };

  config = lib.mkIf wg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = wg.fullAccessSubnet == null || within wg.fullAccessSubnet wg.clientSubnet;
            message = "selfhost.apps.wireguard.fullAccessSubnet (${toString wg.fullAccessSubnet}) must be a block within clientSubnet (${wg.clientSubnet}); a device's tier is its address, so an address outside the client subnet is one nothing routes.";
          }
          {
            assertion = !useNetworkd || config.systemd.network.netdevs ? ${netdevName};
            message = "selfhost.apps.wireguard: no systemd.network.netdevs.${netdevName}, so the peers drop-in would attach to nothing. nixpkgs renamed the WireGuard netdev; update netdevName.";
          }
        ];

        selfhost.services.wireguard = {
          displayName = lib.mkDefault "WireGuard";
          meta.description = lib.mkDefault "VPN";

          # The server private key is left out, so a leaked backup cannot stand up the tunnel.
          backup.package = pkgs.writeShellApplication {
            name = "backup-wireguard";
            text = ''
              if [ -e ${peersFile} ]; then
                cp -a ${peersFile} "$OUTPUT_DIR/"
              else
                echo "No ${peersFile} yet; nothing to back up."
              fi
            '';
          };
          # No port: a UDP daemon, so it is neither routed nor healthchecked.

          integrations.monitoring = {
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

        selfhost.internal.listeningPorts = [
          {
            name = "wireguard/tunnel";
            host = "0.0.0.0";
            port = wg.listenPort;
            protocol = "udp";
          }
        ];

        systemd.tmpfiles.rules = [
          "d ${dataDir} 0700 root root -"
          "d ${dataDir}/server 0700 root root -"
        ]
        ++ lib.optional useNetworkd "d ${peersDropInDir} 0755 root root -";

        systemd.services.wireguard-keygen = {
          description = "WireGuard keygen";
          wantedBy = [ ifaceBackend ];
          before = [ ifaceBackend ];
          after = [ "systemd-tmpfiles-setup.service" ];
          serviceConfig = {
            Type = "oneshot";
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            ReadWritePaths = [ dataDir ];
          };
          path = [ pkgs.wireguard-tools ];
          script = ''
            if [ ! -f "${serverKeyFile}" ]; then
              echo "Generating Wireguard key..."
              (umask 077; wg genkey > ${serverKeyFile})
            fi
            # Derived from the private key, so regenerate whenever it is missing — not only alongside it.
            if [ ! -f "${serverPubKeyFile}" ]; then
              wg pubkey < ${serverKeyFile} > ${serverPubKeyFile}
            fi
            echo "Wireguard key ready."
          '';
        };

        # Peers are runtime state owned by `wg-manage` and applied below.
        networking.wireguard.interfaces.${wg.interface} = {
          ips = [ wg.address ];
          inherit (wg) listenPort;
          privateKeyFile = serverKeyFile;
          peers = [ ];
        };

        networking.firewall.allowedUDPPorts = lib.optionals wg.openFirewall [ wg.listenPort ];

        # Restores peers when wg0 appears, since networkd being up does not mean the device exists yet.
        systemd.services.wireguard-apply-peers = {
          description = "Apply ${wg.interface} peers from ${peersFile}";
          after = [
            ifaceBackend
            "sys-subsystem-net-devices-${wg.interface}.device"
          ];
          bindsTo = [ "sys-subsystem-net-devices-${wg.interface}.device" ];
          wantedBy = [ "sys-subsystem-net-devices-${wg.interface}.device" ];
          path = [ wgManage ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            NoNewPrivileges = true;
            ProtectKernelTunables = true;
            ProtectControlGroups = true;
            RestrictSUIDSGID = true;
            ReadWritePaths = lib.optional useNetworkd peersDropInDir;
          };
          script = "wg-manage apply";
        };

        environment.systemPackages = [ wgManage ];
      }

      # One table, so `nft list table` shows all of it and a reload is atomic.
      {
        networking.nftables.enable = true;
        networking.nftables.tables.wireguard-access = {
          family = "inet";
          content = restrictChain + lanChains;
        };
      }

      (lib.mkIf wg.lanAccess.enable {
        boot.kernel.sysctl = {
          "net.ipv4.ip_forward" = 1;
        }
        // lib.optionalAttrs wg.lanAccess.wakeOnLan {
          # Forwarded directed broadcasts need both `all` and the ingress interface to opt in; udev sets the latter.
          "net.ipv4.conf.all.bc_forwarding" = 1;
          "net.ipv4.conf.${wg.interface}.bc_forwarding" = 1;
        };
      })
    ]
  );
}
