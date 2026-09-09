{ lib, ... }:
{
  options.selfhost.ingress = {
    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Base domain for publicly routed services (e.g. 'home.example.com'). Required once any service enables ingress; a host that routes nothing may leave it null.";
    };

    acme = {
      email = lib.mkOption {
        type = lib.types.str;
        description = "ACME account email for certificate registration";
      };

      dnsProvider = lib.mkOption {
        type = lib.types.str;
        description = "DNS-01 challenge provider name for the ACME client (e.g. 'cloudflare')";
      };

      credentialsEnvFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to an env file with the DNS provider's credentials (e.g. CF_DNS_API_TOKEN). Provided by the host, e.g. via sops-nix.";
      };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether the ingress implementation opens 80/443. Enabling ingress means wanting it reachable, so this follows. Turn it off to place the rules yourself.";
    };

    allowedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "eth0" ];
      description = "Interfaces to scope the opened ports to. Empty opens them on all interfaces. To open nothing at all, set `openFirewall = false` rather than clearing this.";
    };
  };
}
