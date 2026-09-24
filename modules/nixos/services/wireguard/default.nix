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
  # wireguard-<iface>.service otherwise), so anchor keygen on it.
  ifaceBackend =
    if config.networking.wireguard.useNetworkd then "systemd-networkd.service" else "wireguard-${wg.interface}.service";

  dataDir = "/var/lib/wireguard";
  serverKeyFile = "${dataDir}/server/private.key";
  serverPubKeyFile = "${dataDir}/server/public.key";
  peersFile = "${dataDir}/peers.json";

  # Ahead of nixos-fw so it polices what those services opened on the tunnel, and new connections only,
  # so traffic the server itself initiated is untouched. An accept here skips this chain's drop, not
  # nixos-fw: every base chain on the hook still runs. The v6 drop is not redundant, since `ip saddr`
  # cannot match a v6 packet and it would fall through to whatever nixos-fw opened, family-agnostic.
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

  # A magic packet is only useful as a broadcast (a powered-off host answers no ARP), so WoL is the one
  # directed broadcast let through, on the magic-packet ports and from full-access clients only.
  # `fib daddr type` classifies the destination without deriving the broadcast address from the subnet.
  wolRules = lib.optionals (wg.lanAccess.wakeOnLan && wg.fullAccessSubnet != null) [
    ''iifname "${wg.interface}" ip saddr ${wg.fullAccessSubnet} fib daddr type broadcast udp dport { 7, 9 } accept comment "Wake-on-LAN"''
    ''iifname "${wg.interface}" fib daddr type broadcast drop''
  ];

  # Govern only WireGuard clients: full-access addresses forward to the LAN, the rest reach just the
  # server. Other forwarding (containers, bridges) is left to whatever manages it, so this never has to
  # know about podman/microvm/etc.
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

  # AllowedIPs is the client's routing table, so it decides what the device diverts away from its own
  # network, not what it is permitted to reach. A restricted device therefore routes the server alone:
  # sending it the whole LAN subnet captures the local network of anyone whose home uses the same one.
  allowedIPsFull = [ wg.clientSubnet ] ++ lib.optional wg.lanAccess.enable wg.lanAccess.subnet;
  allowedIPsRestricted =
    if wg.lanAccess.enable && wg.lanAccess.serverAddress != null then
      [
        wg.clientSubnet
        "${wg.lanAccess.serverAddress}/32"
      ]
    else
      allowedIPsFull;

  # `fullAccessSubnet` has to name a block inside `clientSubnet`. Outside it both halves fail closed
  # but neither says why: the chain exempts a prefix no client can hold, and `add --full-access`
  # reports no free address because it only ever allocates out of `clientSubnet`.
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

  # One generated file rather than a spread of env vars, matching pocket-id-manage. It carries the
  # address plan and the peer file's path, so allocation, policy and status all resolve a device's
  # tier the same way the nftables chain above does.
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
    }
  );

  wgManage = pkgs.writeShellApplication {
    name = "wg-manage";
    runtimeInputs = [ pkgs.selfhost.wg-manage ];
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
      description = ''
        DNS server pushed to clients. A resolver the device reaches over its own connection works for
        every device, and is what makes `<subdomain>.<domain>` resolve before the tunnel carries the
        request.

        Naming this host instead takes `restrictedPeers.udpPorts = [ 53 ]`, since a device outside
        `fullAccessSubnet` reaches only the ports listed there.
      '';
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

    # What a device outside `fullAccessSubnet` reaches on this host, the counterpart to `lanAccess` governing
    # what a full-access one reaches beyond it.
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
        ];

        selfhost.services.wireguard = {
          displayName = lib.mkDefault "WireGuard";
          meta.description = lib.mkDefault "VPN";

          # Device names, addresses and public keys. The server private key is deliberately left out:
          # a leaked backup must not let anyone stand up the tunnel, and losing it costs one new config
          # per device rather than a re-enrolment, since client keys and addresses survive here.
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
          # No port: WireGuard is a UDP daemon with no HTTP backend, so it is neither routed nor
          # healthchecked. The entry exists for its metadata and metrics; the tunnel socket is
          # registered below.

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
        ];

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

        # No peers here: they are runtime state that `wg-manage` owns and applies live (see
        # wireguard-apply-peers below). This declares only the interface and the server key.
        networking.wireguard.interfaces.${wg.interface} = {
          ips = [ wg.address ];
          inherit (wg) listenPort;
          privateKeyFile = serverKeyFile;
          peers = [ ];
        };

        networking.firewall.allowedUDPPorts = lib.optionals wg.openFirewall [ wg.listenPort ];

        # Peers are runtime state that `wg-manage` writes and applies live, so this only restores them
        # after the interface is recreated. Bound to the device rather than the target: networkd being
        # up does not mean wg0 exists yet, and this way a reconfigure re-applies too.
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
          };
          script = "wg-manage apply";
        };

        environment.systemPackages = [ wgManage ];
      }

      # One table, three chains, rather than a table per concern: `nft list table inet wireguard-access`
      # then shows everything this module installs, and a reload is one atomic delete-and-add.
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
          # Routing drops a forwarded directed broadcast before the filter ever sees it, unless both
          # `all` and the ingress interface opt in (AND, not OR, so no other interface is affected);
          # the interface entry is applied by udev once the interface appears.
          "net.ipv4.conf.all.bc_forwarding" = 1;
          "net.ipv4.conf.${wg.interface}.bc_forwarding" = 1;
        };
      })
    ]
  );
}
