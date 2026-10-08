# First-party coturn app: a STUN/TURN relay for apps whose clients need one to reach each other.
# Logins are registered by those apps, so nothing here names a service.
{
  config,
  lib,
  ...
}:
let
  cfg = config.selfhost;
  app = cfg.apps.coturn;
  coturnCfg = config.services.coturn;

  # Private to the nixpkgs module, which copies its store config here before start. Guarded below.
  runConfig = "/run/coturn/turnserver.cfg";

  secretName = login: "coturn-${login}";
  logins = lib.unique app.logins;
in
{
  options.selfhost.apps.coturn = {
    enable = lib.mkEnableOption "the first-party coturn app (STUN/TURN relay)";

    logins = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      example = [ "romm" ];
      description = "Long-term credential logins to provision, one generated password each. An app needing the relay appends the login it authenticates with.";
    };

    advertisedAddresses = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      example = [
        "192.168.1.10"
        "10.100.0.1"
      ];
      description = "Addresses clients reach this relay on, in the order they should try them. Read by whoever advertises the relay.";
    };

    allowedPeerRanges = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      example = [ "192.168.1.0-192.168.1.255" ];
      description = "Peers relaying is permitted to, in coturn's `allowed-peer-ip` syntax. Every other address is denied, so empty relays nowhere and `0.0.0.0-255.255.255.255` is a public relay.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the listening port and the relay port range on every interface. Off because a relay serving LAN or VPN clients wants an interface-scoped rule instead.";
    };

    credential = lib.mkOption {
      type = lib.types.attrsOf (lib.types.attrsOf lib.types.str);
      readOnly = true;
      default = lib.genAttrs logins (login: {
        file = cfg.runtimeSecrets.${secretName login}.path;
        placeholder = cfg.runtimePlaceholder.${secretName login};
      });
      defaultText = lib.literalMD "derived from `logins`";
      description = "Per login: the generated password's `file`, and its `placeholder` for a `runtimeTemplates` body.";
    };
  };

  config = lib.mkIf app.enable {
    assertions = [
      {
        assertion = lib.length app.logins == lib.length logins;
        message = "selfhost.apps.coturn.logins lists a login twice (${toString app.logins}). One login has one password, so a second definition of it would silently take over.";
      }
    ];

    selfhost = {
      services.coturn = {
        displayName = lib.mkDefault "coturn";
        meta.description = lib.mkDefault "STUN/TURN relay";
        # No port: a UDP relay has no HTTP backend to route or healthcheck. The entry carries the unit,
        # which is what notifies on failure.
        systemdServices = [ "coturn" ];
      };

      internal.listeningPorts = [
        {
          name = "coturn/turn";
          host = "0.0.0.0";
          port = coturnCfg.listening-port;
          protocol = "udp";
        }
      ];

      runtimeSecrets = lib.genAttrs (map secretName logins) (_: {
        bytes = 16;
        restartUnits = [ "coturn.service" ];
      });
    };

    services.coturn = {
      enable = true;
      lt-cred-mech = true; # not a default: the logins below are the only auth this app provisions
      no-cli = lib.mkDefault true;
      no-tcp-relay = lib.mkDefault true;
      extraConfig = ''
        no-multicast-peers
        denied-peer-ip=0.0.0.0-255.255.255.255
        denied-peer-ip=::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
        ${lib.concatMapStringsSep "\n" (range: "allowed-peer-ip=${range}") app.allowedPeerRanges}
      '';
    };

    # Passwords reach coturn through the runtime config it already assembles, never the store.
    systemd.services.coturn = {
      serviceConfig.LoadCredential = map (login: "${login}:${app.credential.${login}.file}") logins;
      preStart = lib.mkAfter ''
        test -f ${runConfig}
        ${lib.concatMapStringsSep "\n" (login: ''
          printf 'user=%s:%s\n' ${lib.escapeShellArg login} "$(cat "$CREDENTIALS_DIRECTORY/${login}")" >> ${runConfig}
        '') logins}
      '';
    };

    networking.firewall = lib.mkIf app.openFirewall {
      allowedUDPPorts = [ coturnCfg.listening-port ];
      allowedUDPPortRanges = [
        {
          from = coturnCfg.min-port;
          to = coturnCfg.max-port;
        }
      ];
    };
  };
}
