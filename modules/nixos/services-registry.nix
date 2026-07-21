{ lib, config, ... }:
let
  cfg = config.selfhost;
  selfhostLib = import ./lib.nix { inherit lib; };

  # Every group a policy may name: the canonical set plus any group a user actually holds. Keeps
  # allowedGroups symmetric with the free-form user.groups (a custom group becomes nameable in policy
  # once some user is in it) while still catching typos.
  knownGroups = lib.unique (lib.attrValues cfg.groups ++ lib.concatMap (u: u.groups) (lib.attrValues cfg.users));

  baseServiceModule = { name, config, ... }: {
    # No ingress route means no link to render, so default to no dashboard tile.
    config.integrations.homepage.enable = lib.mkDefault config.ingress.enable;

    options = {
      # Routing (backend)
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Hostname or IP where the service listens (local or remote)";
      };

      port = lib.mkOption {
        type = lib.types.port;
        description = "Port the service listens on";
      };

      scheme = lib.mkOption {
        type = lib.types.enum [
          "http"
          "https"
        ];
        default = "http";
        description = "URL scheme for backend connection";
      };

      url = lib.mkOption {
        type = lib.types.str;
        default = "${config.scheme}://${config.host}:${toString config.port}";
        defaultText = lib.literalMD "`<scheme>://<host>:<port>`";
        description = "Full URL for proxying (derived from scheme, host and port)";
      };

      healthcheck.path = lib.mkOption {
        type = lib.types.str;
        default = "/";
        description = "Path for health checks (used by monitoring and homepage)";
      };

      healthcheck.url = lib.mkOption {
        type = lib.types.str;
        default = "${config.url}${config.healthcheck.path}";
        defaultText = lib.literalMD "`<url><healthcheck.path>`";
        readOnly = true;
        description = "Full health check URL (derived from url and healthcheck path)";
      };

      healthcheck.probeModule = lib.mkOption {
        type = lib.types.enum [
          "http_2xx"
          "http_any"
        ];
        default = "http_2xx";
        description = "Blackbox exporter module for health probes. Use http_any for services that require authentication on all endpoints.";
      };

      # Routing (public)
      subdomain = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Subdomain prefix (combined with domain for publicHost)";
      };

      publicHost = lib.mkOption {
        type = lib.types.str;
        default = "${config.subdomain}.${cfg.domain}";
        defaultText = lib.literalMD "`<subdomain>.<domain>`";
        description = "Public hostname (derived from subdomain and domain)";
      };

      publicUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://${config.publicHost}";
        defaultText = lib.literalMD "`https://<publicHost>`";
        description = "Full public URL (derived from publicHost)";
      };

      ingress.enable = lib.mkEnableOption "HTTP ingress route for this service" // {
        default = true;
      };

      # Access control policy (consumed by whichever auth mechanism is active). Empty = any authenticated user.
      access.allowedGroups = lib.mkOption {
        type = lib.types.listOf (lib.types.enum knownGroups);
        default = [ ];
        description = "Groups authorized to access this service (canonical groups or any a user is in). Empty means unrestricted (any authenticated user).";
      };

      # Pre-backup hook (consumed by backup.nix)
      backup = {
        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = "Package providing backup script. Use writeShellApplication with runtimeInputs for dependencies. OUTPUT_DIR is provided as an environment variable pointing to a fresh, empty directory for the hook's output.";
        };

        after = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Systemd services this backup hook requires and orders after.";
        };

      };

    };
  };
in
{
  options.selfhost = {
    enable = lib.mkEnableOption "home-server services";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "Base domain for all services (e.g. 'home.example.com')";
    };

    services = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submoduleWith {
          specialArgs = {
            selfhostCfg = cfg;
          };
          modules = [
            ./schemas/metadata.nix
            baseServiceModule
            ./schemas/ingress.nix
            ./schemas/oidc.nix
            ./schemas/storage.nix
            ./schemas/homepage.nix
            ./schemas/notify.nix
            ./schemas/monitoring.nix
            ./schemas/extra.nix
          ];
        }
      );
      default = { };
      description = "Registry of selfhost services: routing, metadata, and integrations (HTTP ingress optional via ingress.enable).";
    };

    external = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule [
          ./schemas/metadata.nix
          ./schemas/homepage.nix
          {
            options.url = lib.mkOption {
              type = lib.types.str;
              description = "Direct URL to the external service";
            };

            # External entries exist solely to appear on the dashboard.
            config.integrations.homepage.enable = lib.mkDefault true;
          }
        ]
      );
      default = { };
      description = "External services not managed by this host (shown on homepage dashboard via integrations.homepage)";
    };

    # Port registry: modules append their local listening sockets (services here, exporters in
    # monitoring.nix, ...); the assertion below checks the whole set is collision-free.
    internal.listeningPorts = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Owner identifier, shown in collision messages.";
            };
            host = lib.mkOption {
              type = lib.types.str;
              default = "127.0.0.1";
              description = "Listen address.";
            };
            port = lib.mkOption {
              type = lib.types.port;
              description = "Listen port.";
            };
          };
        }
      );
      default = [ ];
      internal = true;
      description = "Local listening sockets registered across the framework; asserted collision-free.";
    };

  };

  config = lib.mkIf cfg.enable {
    # A remote proxy target binds nothing here, so only local listeners can collide.
    selfhost.internal.listeningPorts = map (s: {
      name = "service/${s.name}";
      inherit (s) host port;
    }) (lib.filter (s: s.host == "127.0.0.1" || s.host == "localhost") (lib.attrValues cfg.services));

    assertions =
      let
        allServices = lib.attrValues cfg.services;

        # Public hosts must be unique across ingress-enabled services.
        ingressHosts = map (s: s.publicHost) (lib.filter (s: s.ingress.enable) allServices);
        dupHosts = lib.attrNames (selfhostLib.collisions (builtins.groupBy lib.id ingressHosts));

        # One check over the whole registry: services + monitoring exporters + anything else registered.
        portCollisions = selfhostLib.collisions (
          builtins.groupBy (e: selfhostLib.socket e.host e.port) cfg.internal.listeningPorts
        );

        dualAuth = lib.filter (s: s.oidc.enable && s.forwardAuth.enable) allServices;
        names = lib.concatMapStringsSep ", " (x: x.name);
      in
      [
        {
          assertion = dupHosts == [ ];
          message = "Service public hosts must be unique. Conflicting: ${lib.concatStringsSep ", " dupHosts}";
        }
        {
          assertion = portCollisions == { };
          message = "Listening port collisions: ${
            lib.concatStringsSep "; " (lib.mapAttrsToList (socket: group: "${socket} ← ${names group}") portCollisions)
          }";
        }
        {
          assertion = dualAuth == [ ];
          message = "Services must not enable both OIDC and forwardAuth. Offending: ${names dualAuth}";
        }
      ];

    # allowedGroups are only enforced by a framework auth mechanism; a service that sets them but
    # enables neither relies on its own auth (or is unrestricted). Warn, don't block; the framework
    # can't tell deliberate native-auth from a forgotten enforcer.
    warnings =
      let
        unenforced = lib.filter (s: s.access.allowedGroups != [ ] && !s.oidc.enable && !s.forwardAuth.enable) (
          lib.attrValues cfg.services
        );
      in
      lib.optional (unenforced != [ ])
        "Services set access.allowedGroups but enable no framework auth (oidc/forwardAuth), so the groups are not enforced; the service must authenticate itself: ${
          lib.concatMapStringsSep ", " (s: s.name) unenforced
        }";
  };
}
