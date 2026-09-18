{
  lib,
  config,
  options,
  ...
}:
let
  selfhostCfg = config.selfhost;
  selfhostLib = import ../lib.nix { inherit lib; };
  cfg = selfhostCfg.auth.oidc;
  # Persistent (not tmpfs): these have no source to re-derive from, so a tmpfs would regenerate them every
  # boot → drift. Persisting (rotate-when-missing keeps the file) makes them stable; rotation is deliberate.
  credentialsBaseDir = "/var/lib/homelab-oidc";

  oidcServices = lib.filterAttrs (_: svc: svc.access.model == "oidc") selfhostCfg.services;

  derivedClients = lib.mapAttrs (_: svc: svc.access.oidc // { inherit (svc.access) allowedGroups; }) oidcServices;

  enabledUsers = lib.filterAttrs (_: u: u.auth.oidc.enable) selfhostCfg.users;

  # Every group a policy may name, not just the ones an OIDC user holds: `access.allowedGroups` accepts
  # the wider set, and a group the provider never heard of fails client provisioning at boot. A group
  # whose only members opted out of OIDC lands here empty, which is what it means.
  allGroups = selfhostLib.knownGroups selfhostCfg;
in
{
  options.selfhost.auth.oidc = {
    active = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      default = options.selfhost.auth.oidc.provider.issuerUrl.isDefined;
      defaultText = lib.literalMD "true once a provider defines `provider.issuerUrl`";
      description = "Whether an OIDC provider is active. Compose service defaults against this.";
    };

    provider = {
      displayName = lib.mkOption {
        type = lib.types.str;
        description = "Display name of the OIDC provider (shown in UI)";
      };

      internalName = lib.mkOption {
        type = lib.types.str;
        description = "Internal name for URLs and identifiers";
      };

      issuerUrl = lib.mkOption {
        type = lib.types.str;
        description = "OIDC issuer URL (e.g. https://auth.example.com). Left undefined until a provider sets it, which is what `active` reads.";
      };

      discoveryUrl = lib.mkOption {
        type = lib.types.str;
        default = "${cfg.provider.issuerUrl}/.well-known/openid-configuration";
        defaultText = lib.literalMD "`<issuerUrl>/.well-known/openid-configuration`";
        readOnly = true;
        description = "OIDC discovery document URL (derived from issuerUrl); for consumers that need the full well-known URL rather than the bare issuer.";
      };

      apiKeyFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to file containing provider API key";
      };
    };

    credentials = {
      dir = lib.mkOption {
        type = lib.types.str;
        default = credentialsBaseDir;
        readOnly = true;
        description = "Base directory for OIDC credentials (persistent; see credentialsBaseDir).";
      };

      usersFile = lib.mkOption {
        type = lib.types.str;
        default = "${credentialsBaseDir}/oidc-users.json";
        readOnly = true;
        description = "JSON file mapping usernames to their OIDC provider user IDs";
      };
    };

    clients = lib.mkOption {
      # Raw passthrough: mirrors the already-typed schemas/oidc.nix submodule, so re-declaring
      # the fields here only risked drift. Read-only; consumers read attrs directly.
      type = lib.types.attrsOf lib.types.raw;
      default = derivedClients;
      readOnly = true;
      description = "Derived OIDC client configs keyed by service name (read-only)";
    };

    provisionConfig = lib.mkOption {
      # Raw passthrough: consumers read attrs directly; typing it here only risked drift (mirrors clients above).
      type = lib.types.raw;
      readOnly = true;
      default = {
        users = lib.mapAttrsToList (_: u: {
          inherit (u)
            username
            email
            firstName
            lastName
            isAdmin
            groups
            ;
          inherit (u.auth.oidc) inviteByEmail;
        }) enabledUsers;
        groups = map (name: { inherit name; }) allGroups;
      };
      description = "Provisioning config derived from OIDC-enabled users and services (read-only)";
    };

    systemd = {
      baseProvisionUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Systemd unit for base OIDC provisioning (users/groups)";
      };

      clientProvisionUnitPrefix = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Prefix for per-client provisioning unit names (provider sets this; e.g. '<provider>-provision-client-' yields '<provider>-provision-client-<name>.service').";
      };
    };
  };

  config = lib.mkIf (derivedClients != { }) (
    let
      allDependentServices = lib.concatLists (
        lib.mapAttrsToList (_: client: client.systemd.dependentServices) derivedClients
      );
      hasProvisionUnits = cfg.systemd.baseProvisionUnit != null;
      invitedUsers = lib.attrNames (lib.filterAttrs (_: u: u.auth.oidc.inviteByEmail) enabledUsers);
      # Scoped to OIDC users: the provider rejects a domain without a dot, while a placeholder like
      # `guest@localhost` stays legal for accounts that never reach it.
      badEmails = lib.attrNames (
        lib.filterAttrs (_: u: builtins.match "[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+" u.email == null) enabledUsers
      );
    in
    {
      assertions = [
        {
          assertion = badEmails == [ ];
          message = "OIDC users whose email the provider will reject, because the domain has no dot: ${toString badEmails}. A create failure aborts provisioning for every other user in the same run, so this is caught here. Use a reserved placeholder domain such as local.invalid.";
        }
        {
          assertion = invitedUsers == [ ] || selfhostCfg.mail.active;
          message = "Users ask for an emailed OIDC enrolment link but selfhost.mail is unset: ${toString invitedUsers}. Configure selfhost.mail, or leave auth.oidc.inviteByEmail off and mint the link with `pocket-id one-time-access-token <user>`.";
        }
        {
          assertion = hasProvisionUnits || allDependentServices == [ ];
          message = "selfhost.auth.oidc.systemd.baseProvisionUnit must be set when OIDC clients have dependentServices configured. Without it, systemd ordering is silently skipped.";
        }
      ];

      users.groups = lib.mapAttrs' (_: client: lib.nameValuePair client.group { }) derivedClients;

      systemd.services = lib.mkIf hasProvisionUnits (
        lib.mkMerge (
          lib.mapAttrsToList (
            name: client:
            let
              clientProvisionUnit = "${cfg.systemd.clientProvisionUnitPrefix}${name}.service";
            in
            lib.listToAttrs (
              map (svcName: {
                name = svcName;
                value = {
                  requires = [ clientProvisionUnit ];
                  after = [ clientProvisionUnit ];
                  partOf = [ clientProvisionUnit ];
                };
              }) client.systemd.dependentServices
            )
          ) derivedClients
        )
      );
    }
  );
}
