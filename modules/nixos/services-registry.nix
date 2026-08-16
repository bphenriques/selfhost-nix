{ lib, config, ... }:
let
  cfg = config.selfhost;
  selfhostLib = import ./lib.nix { inherit lib; };

  # Every group a policy may name: the canonical set plus any group a user actually holds. Keeps
  # allowedGroups symmetric with the free-form user.groups (a custom group becomes nameable in policy
  # once some user is in it) while still catching typos.
  knownGroups = lib.unique (lib.attrValues cfg.groups ++ lib.concatMap (u: u.groups) (lib.attrValues cfg.users));

  # A container's unit is named for its backend, not the service, so the default follows suit.
  ociContainers = config.virtualisation.oci-containers.containers or { };
  ociBackend = config.virtualisation.oci-containers.backend or "podman";

  baseServiceModule =
    {
      name,
      config,
      options,
      ...
    }:
    {
      # No ingress route means no link to render, so default to no dashboard tile.
      config.integrations.homepage.enable = lib.mkDefault config.ingress.enable;

      # Route it only if there is something to route to, and if its access model is satisfied:
      # `forwardAuth` is the one model where the service authenticates nobody itself, so it waits for the
      # gateway rather than going up unguarded. The others carry their own login.
      config.ingress.enable = lib.mkDefault (
        (config.backend != null || options.port.isDefined)
        && (config.access.model != "forwardAuth" || cfg.auth.forwardAuth.active)
      );

      # The probe targets the backend, so an entry borrowing one would only re-probe what its owner
      # already does — same URL, second alert on one outage.
      config.integrations.monitoring.healthcheck = lib.mkDefault (config.backend == null);

      # `backend` first so a borrowed entry short-circuits: it has no port definition of its own.
      config.ownsBackend = config.backend == null && options.port.isDefined;
      config.port = lib.mkIf (config.backend != null) cfg.services.${config.backend}.port;

      options = {
        # Routing (backend)
        backend = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          example = "radicale";
          description = ''
            Another registry entry whose backend this one routes to, instead of owning one. Its
            `host`/`port`/`scheme` become this entry's, and only the owner is counted for port collisions.

            For a second hostname onto the same process — one that wants its own `access.model`,
            middlewares or healthcheck. Null means this entry owns its backend.
          '';
        };

        ownsBackend = lib.mkOption {
          type = lib.types.bool;
          readOnly = true;
          defaultText = lib.literalMD "true when `port` is set and `backend` is not";
          description = "Whether this entry's `host:port` is a socket it actually listens on (read-only).";
        };

        host = lib.mkOption {
          type = lib.types.str;
          default = if config.backend == null then "127.0.0.1" else cfg.services.${config.backend}.host;
          defaultText = lib.literalMD "`127.0.0.1`, or the `backend` entry's host";
          description = "Hostname or IP where the service listens (local or remote)";
        };

        port = lib.mkOption {
          type = lib.types.port;
          # Deliberately no default: absence is the signal that this entry has no HTTP backend, and
          # `isDefined` reads it. A default here would be evaluated by that check, so a borrowed port
          # is *defined* below rather than defaulted.
          description = "Port the service listens on. Leave unset for a service with no HTTP backend (a UDP daemon, say).";
        };

        scheme = lib.mkOption {
          type = lib.types.enum [
            "http"
            "https"
          ];
          default = if config.backend == null then "http" else cfg.services.${config.backend}.scheme;
          defaultText = lib.literalMD "`http`, or the `backend` entry's scheme";
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
          # Thrown rather than nullOr: keeping the type `str` spares every reader a null branch for a
          # case that cannot happen on a host that routes anything.
          default =
            if cfg.ingress.domain == null then
              throw "selfhost.services.${name}.publicHost needs selfhost.ingress.domain, which is unset."
            else
              "${config.subdomain}.${cfg.ingress.domain}";
          defaultText = lib.literalMD "`<subdomain>.<ingress.domain>`";
          description = "Public hostname (derived from subdomain and ingress.domain)";
        };

        publicUrl = lib.mkOption {
          type = lib.types.str;
          default = "https://${config.publicHost}";
          defaultText = lib.literalMD "`https://<publicHost>`";
          description = "Full public URL (derived from publicHost)";
        };

        systemdServices = lib.mkOption {
          type = lib.types.coercedTo lib.types.str (s: [ s ]) (lib.types.listOf lib.types.str);
          default =
            if config.backend != null then
              cfg.services.${config.backend}.systemdServices
            else if ociContainers ? ${name} then
              [ "${ociBackend}-${name}" ]
            else
              [ name ];
          defaultText = lib.literalMD "the `backend` entry's units, else the matching OCI container's unit, else `<name>`";
          description = ''
            Systemd units this service owns; selfhost concerns attach to them (storage automount guards,
            failure notifications).

            Names are trusted, not checked: attaching ordering to a unit is what *defines* it, so a name
            that matches nothing yields a stub carrying only the attachment rather than an error. Set this
            when the unit is not named after the service.
          '';
        };

        ingress.enable = lib.mkEnableOption "HTTP ingress route for this service" // {
          default = true;
        };

        access.model = lib.mkOption {
          type = lib.types.enum [
            "oidc"
            "forwardAuth"
            "native"
            "open"
          ];
          default = "native";
          description = ''
            Who authenticates this service's users.

            - `oidc`: the service is its own client of the framework's OIDC provider (configure it under
              `access.oidc`).
            - `forwardAuth`: the gateway authenticates before the service sees the request. The service
              has no login of its own, so it is routed only while a forward-auth provider is active.
            - `native`: the service authenticates its own users by a mechanism the framework does not
              manage.
            - `open`: nobody authenticates. Anyone who can reach the route can use it. This says the service
              has no lock, not that it faces the internet — nothing is exposed beyond
              `ingress.allowedInterfaces` under any model.

            Only `oidc` and `forwardAuth` let the framework enforce `access.allowedGroups`.
          '';
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
    # Only sockets this host actually listens on can collide: a remote proxy target binds nothing here,
    # an entry routing to another's backend binds nothing of its own, and an entry with no HTTP backend
    # has no socket to speak of.
    selfhost.internal.listeningPorts = map (s: {
      name = "service/${s.name}";
      inherit (s) host port;
    }) (lib.filter (s: s.ownsBackend && (s.host == "127.0.0.1" || s.host == "localhost")) (lib.attrValues cfg.services));

    assertions =
      let
        allServices = lib.attrValues cfg.services;

        ingressServices = lib.filter (s: s.ingress.enable) allServices;

        # Public hosts must be unique across ingress-enabled services. Guarded on domain so a missing
        # one reports the assertion below instead of publicHost's throw.
        ingressHosts = if cfg.ingress.domain == null then [ ] else map (s: s.publicHost) ingressServices;
        dupHosts = lib.attrNames (selfhostLib.collisions (builtins.groupBy lib.id ingressHosts));

        # One check over the whole registry: services + monitoring exporters + anything else registered.
        portCollisions = selfhostLib.collisions (
          builtins.groupBy (e: selfhostLib.socket e.host e.port) cfg.internal.listeningPorts
        );

        oidcServices = lib.filter (s: s.access.model == "oidc") allServices;

        danglingBackends = lib.filter (
          s: s.backend != null && (s.backend == s.name || !(cfg.services ? ${s.backend}))
        ) allServices;

        names = lib.concatMapStringsSep ", " (x: x.name);
      in
      [
        {
          assertion = ingressServices == [ ] || cfg.ingress.domain != null;
          message = "selfhost.ingress.domain must be set when any service enables ingress. Routed services: ${names ingressServices}";
        }
        {
          assertion = danglingBackends == [ ];
          message = "Services set access to another entry's backend that is not registered (or is themselves): ${
            lib.concatMapStringsSep ", " (s: "${s.name} -> ${s.backend}") danglingBackends
          }";
        }
        {
          assertion = dupHosts == [ ];
          message = "Service public hosts must be unique. Conflicting: ${lib.concatStringsSep ", " dupHosts}";
        }
        {
          # Nothing provisions the client without a provider, so the service would come up
          # authenticating nobody while the inventory reported it as SSO. The forwardAuth counterpart
          # of this lives in the ingress implementation, which is what applies that gate.
          assertion = oidcServices == [ ] || cfg.auth.oidc.active;
          message = "Services set access.model = \"oidc\" but no OIDC provider is active (enable one, e.g. selfhost.auth.oidc.pocket-id.enable): ${names oidcServices}";
        }
        {
          assertion = portCollisions == { };
          message = "Listening port collisions: ${
            lib.concatStringsSep "; " (lib.mapAttrsToList (socket: group: "${socket} ← ${names group}") portCollisions)
          }";
        }
      ];

    # Only `oidc` and `forwardAuth` put the framework in the request path, so only they can enforce
    # groups. Under the other two the service decides for itself, which is a legitimate choice — hence
    # a warning naming what to do about it, not a hard failure.
    warnings =
      let
        unenforced = lib.filter (
          s:
          s.access.allowedGroups != [ ]
          && !(lib.elem s.access.model [
            "oidc"
            "forwardAuth"
          ])
        ) (lib.attrValues cfg.services);
      in
      lib.optional (unenforced != [ ])
        "Services set access.allowedGroups under an access.model the framework does not enforce, so the groups do nothing. Either set access.model to oidc/forwardAuth, or drop the groups and let the service decide: ${
          lib.concatMapStringsSep ", " (s: "${s.name} (${s.access.model})") unenforced
        }";
  };
}
