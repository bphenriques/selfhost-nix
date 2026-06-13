# Provider-neutral ingress contract: TLS/ACME and which interfaces expose HTTP. The active
# implementation (traefik by default) reads these; per-service routing lives in the registry.
{ lib, ... }:
{
  options.selfhost.ingress = {
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

    allowedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Network interfaces to allow HTTP/HTTPS traffic on. If empty, allows on all interfaces (not recommended).";
    };
  };
}
