{ lib, config, ... }:
let
  cfg = config.selfhost;
  ingressCfg = cfg.ingress;

  mkRouterConfig = service: host: {
    rule = "Host(`${host}`)";
    entryPoints = [ "websecure" ];
    service = "${service.name}-svc";
    middlewares = lib.optionals service.forwardAuth.enable [ "forwardAuth" ] ++ lib.attrNames service.traefik.middlewares;
  };

  mkTraefikRoute =
    service:
    let
      aliasRouters = lib.imap0 (i: alias: {
        name = "${service.name}-alias-${toString i}";
        value = mkRouterConfig service alias;
      }) service.aliases;
    in
    {
      http = {
        routers = {
          "${service.name}" = mkRouterConfig service service.publicHost;
        }
        // lib.listToAttrs aliasRouters;
        services."${service.name}-svc".loadBalancer.servers = [ { inherit (service) url; } ];
      }
      # Traefik's file provider rejects an empty `middlewares: {}`, so only emit it when non-empty.
      // lib.optionalAttrs (service.traefik.middlewares != { }) {
        inherit (service.traefik) middlewares;
      };
    };
in
{
  options.selfhost.ingress.traefik = {
    enable = lib.mkEnableOption "Traefik reverse-proxy ingress implementation";

    metricsPort = lib.mkOption {
      type = lib.types.port;
      default = 8082;
      description = "Port for Traefik's Prometheus metrics endpoint (localhost only)";
    };
  };

  config = lib.mkIf cfg.ingress.traefik.enable {
    # Register the localhost metrics endpoint so it's part of the port-collision check.
    selfhost.internal.listeningPorts = [
      {
        name = "traefik/metrics";
        port = ingressCfg.traefik.metricsPort;
      }
    ];

    selfhost.monitoring.scopes.traefik = {
      scrapeConfigs = [
        {
          job_name = "traefik";
          scrape_interval = "120s";
          static_configs = [
            {
              targets = [ "127.0.0.1:${toString ingressCfg.traefik.metricsPort}" ];
              labels.instance = config.networking.hostName;
            }
          ];
        }
      ];
    };

    assertions =
      let
        forwardAuthServices = lib.filter (s: s.forwardAuth.enable && s.ingress.enable) (lib.attrValues cfg.services);
      in
      [
        {
          assertion = forwardAuthServices == [ ] || cfg.auth.forwardAuth.url != null;
          message = "Services enable forwardAuth but no forward-auth provider is active (selfhost.auth.forwardAuth.url is unset): ${
            lib.concatMapStringsSep ", " (s: s.name) forwardAuthServices
          }. Traefik would silently skip auth for these services.";
        }
      ];

    networking.firewall =
      if ingressCfg.allowedInterfaces == [ ] then
        {
          allowedTCPPorts = [
            80
            443
          ];
        }
      else
        {
          interfaces = lib.genAttrs ingressCfg.allowedInterfaces (_: {
            allowedTCPPorts = [
              80
              443
            ];
          });
        };

    systemd.services.traefik = {
      serviceConfig = {
        EnvironmentFile = ingressCfg.acme.credentialsEnvFile;
        Restart = "on-failure";
        RestartSec = "10s";
        RestartMaxDelaySec = "5min";
        RestartSteps = 5;
      };
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };

    # No rate limiting: all services are behind WireGuard/LAN, keeping config simple.
    services.traefik = {
      enable = true;
      staticConfigOptions = {
        # Defaults the consumer can override directly on services.traefik.staticConfigOptions.*
        log.level = lib.mkDefault "ERROR";
        entryPoints = {
          web = {
            address = "0.0.0.0:80";
            http.redirections.entryPoint = {
              to = "websecure";
              scheme = "https";
            };
          };

          websecure = {
            address = "0.0.0.0:443";

            # Raise for large uploads; entrypoint-scoped (Traefik has no per-router timeout).
            transport.respondingTimeouts = {
              readTimeout = lib.mkDefault "600s";
              idleTimeout = lib.mkDefault "600s";
            };
            http.tls = {
              certResolver = "default";
              domains = [
                {
                  main = cfg.domain;
                  sans = [ "*.${cfg.domain}" ];
                }
              ];
            };
          };
        };

        entryPoints.metrics.address = "127.0.0.1:${toString ingressCfg.traefik.metricsPort}";
        metrics.prometheus = {
          entryPoint = "metrics";
          addRoutersLabels = true;
          addServicesLabels = true;
        };

        certificatesResolvers.default.acme = {
          email = ingressCfg.acme.email;
          storage = "/var/lib/traefik/acme.json";
          dnsChallenge.provider = ingressCfg.acme.dnsProvider;
        };
      };

      dynamicConfigOptions = lib.pipe (lib.attrValues cfg.services) [
        (lib.filter (s: s.ingress.enable))
        (map mkTraefikRoute)
        (
          routes:
          routes
          ++ lib.optional (cfg.auth.forwardAuth.url != null) {
            http.middlewares.forwardAuth.forwardAuth = {
              address = "${cfg.auth.forwardAuth.url}${cfg.auth.forwardAuth.path}";
              trustForwardHeader = true;
              authResponseHeaders = [
                "Remote-User"
                "Remote-Email"
                "Remote-Groups"
                "Remote-Name"
              ];
            };
          }
        )
        (lib.foldl' lib.recursiveUpdate { })
      ];
    };
  };
}
