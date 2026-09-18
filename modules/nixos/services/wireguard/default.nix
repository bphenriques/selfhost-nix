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

  restrictedDevices = lib.filter (c: !c.fullAccess) clients;
  fullAccessDevices = lib.filter (c: c.fullAccess) clients;

  # fullAccess governs forwarding, so it says nothing about this host's own ports. sshd, the reverse
  # proxy and anything else bound to the tunnel interface are otherwise reachable by every peer. Ahead
  # of nixos-fw so it polices what those services opened. New connections only, so traffic the server
  # itself initiated is untouched; everything else from these peers goes, ICMP included, so they cannot
  # ping the host either.
  #
  # The v6 drop is not redundant: this module is IPv4-only, so `ip saddr` cannot match a v6 packet and
  # it would fall through to whatever nixos-fw opened on the tunnel interface, which is family-agnostic.
  # Only the absence of a v6 address on the interface stops that today.
  #
  # Having a restricted device is the whole trigger: empty port lists mean such a device reaches nothing,
  # not that the restriction lifts. A device meant to reach everything carries `fullAccess`.
  restrictApplies = restrictedDevices != [ ];
  restrictChain = lib.optionalString restrictApplies (
    let
      saddr = "ip saddr { ${lib.concatMapStringsSep ", " (c: c.ip) restrictedDevices} }";
      accept =
        proto: ports:
        lib.optional (ports != [ ])
          ''iifname "${wg.interface}" ${saddr} ct state new ${proto} dport { ${
            lib.concatMapStringsSep ", " toString ports
          } } accept'';
      rules = [
        ''iifname "${wg.interface}" meta nfproto ipv6 ct state new drop''
      ]
      ++ accept "tcp" wg.restrictedPeers.tcpPorts
      ++ accept "udp" wg.restrictedPeers.udpPorts
      ++ [ ''iifname "${wg.interface}" ${saddr} ct state new drop'' ];
    in
    ''
      chain input {
        type filter hook input priority filter - 1; policy accept;
        ${lib.concatStringsSep "\n  " rules}
      }
    ''
  );

  # A magic packet is only useful as a broadcast (a powered-off host answers no ARP), so WoL is the one
  # directed broadcast let through, on the magic-packet ports and from full-access clients only.
  # `fib daddr type` classifies the destination without deriving the broadcast address from the subnet.
  wolRules = lib.optionals (wg.lanAccess.wakeOnLan && fullAccessDevices != [ ]) [
    ''iifname "${wg.interface}" ip saddr { ${
      lib.concatMapStringsSep ", " (c: c.ip) fullAccessDevices
    } } fib daddr type broadcast udp dport { 7, 9 } accept comment "Wake-on-LAN"''
    ''iifname "${wg.interface}" fib daddr type broadcast drop''
  ];

  # Govern only WireGuard clients: fullAccess devices forward to the LAN, the rest reach just the
  # server. Other forwarding (containers, bridges) is left to whatever manages it, so this never has to
  # know about podman/microvm/etc.
  forwardRules =
    wolRules
    ++ map (c: ''iifname "${wg.interface}" ip saddr ${c.ip} accept'') fullAccessDevices
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

  # One generated file rather than a spread of env vars, matching pocket-id-manage. Carrying the peer
  # list makes the registry the tool's only inventory: allocation, policy and status all read it, so
  # none of them can disagree with what the server actually routes.
  manageConfigFile = pkgs.writeText "wg-manage-config.json" (
    builtins.toJSON {
      inherit (wg) interface clientSubnet dns;
      serverPublicKeyFile = serverPubKeyFile;
      endpoint = "${wg.endpoint}:${toString wg.listenPort}";
      allowedIPs = {
        full = lib.concatStringsSep "," allowedIPsFull;
        restricted = lib.concatStringsSep "," allowedIPsRestricted;
      };
      peers = map (c: {
        inherit (c)
          name
          ip
          fullAccess
          publicKey
          ;
      }) clients;
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
      example = "1.1.1.1";
      description = ''
        DNS server pushed to clients. A resolver the device reaches over its own connection works for
        every device, and is what makes `<subdomain>.<domain>` resolve before the tunnel carries the
        request.

        Naming this host instead takes `restrictedPeers.udpPorts = [ 53 ]`, since a device without
        `fullAccess` reaches only the ports listed there.
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

    # What a device without `fullAccess` reaches on this host, the counterpart to `lanAccess` governing
    # what a full-access one reaches beyond it.
    restrictedPeers = {
      tcpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [
          80
          443
        ];
        description = "TCP ports on this host a device without `fullAccess` may reach. Everything else another service opened on the tunnel interface is dropped for it. Empty allows none.";
      };

      udpPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [ ];
        example = [ 53 ];
        description = "UDP ports on this host a device without `fullAccess` may reach. Empty allows none, which is why `dns` normally names a resolver these devices reach without the server. Open 53 here instead if the resolver is this host.";
      };
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
          displayName = lib.mkDefault "WireGuard";
          meta.description = lib.mkDefault "VPN";
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
          ];

        # systemd-networkd applies the netdev's peers but never removes one that is no longer declared
        # (verified: neither `networkctl reload` nor `reconfigure` drops a stale peer), so deleting a
        # device from the registry would leave it connectable until the next reboot. The unit's script
        # embeds the declared set, so a changed registry restarts it and revocation lands on deploy.
        systemd.services.wireguard-reconcile-peers = {
          description = "Remove ${wg.interface} peers that are no longer declared";
          wantedBy = [ "multi-user.target" ];
          after = [ ifaceBackend ];
          path = [ pkgs.wireguard-tools ];
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
          script = ''
            declared=${pkgs.writeText "wireguard-declared-peers" (lib.concatMapStringsSep "\n" (c: c.publicKey) clients + "\n")}
            live=$(wg show ${wg.interface} peers 2>/dev/null) || {
              echo "${wg.interface} is not up; nothing to reconcile."
              exit 0
            }
            for pk in $live; do
              if ! grep -qxF "$pk" "$declared"; then
                echo "Removing undeclared peer: $pk"
                wg set ${wg.interface} peer "$pk" remove
              fi
            done
          '';
        };

        environment.systemPackages = [ wgManage ];
      }

      # One table, three chains, rather than a table per concern: `nft list table inet wireguard-access`
      # then shows everything this module installs, and a reload is one atomic delete-and-add.
      (lib.mkIf (restrictApplies || wg.lanAccess.enable) {
        networking.nftables.enable = true;
        networking.nftables.tables.wireguard-access = {
          family = "inet";
          content = restrictChain + lanChains;
        };
      })

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
