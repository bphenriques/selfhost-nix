{
  lib,
  config,
  pkgs,
  ...
}:
let
  cfg = config.selfhost;
  secretsDir = "/var/lib/homelab-secrets"; # persistent
  templatesDir = "/run/homelab-secrets/templates"; # tmpfs; re-rendered each boot

  users = config.users.users;

  resolveGroup =
    item:
    if item.group != null then
      item.group
    else if users ? ${item.owner} then
      users.${item.owner}.group
    else
      item.owner;

  mkPlaceholder = key: "<HOMELAB:${builtins.hashString "sha256" key}:PLACEHOLDER>";

  secretPlaceholderMap = lib.mapAttrs (name: _: mkPlaceholder "secret:${name}") cfg.runtimeSecrets;

  oidcClients = cfg.auth.oidc.clients or { };
  oidcPlaceholderMap = lib.mapAttrs (name: _: {
    id = mkPlaceholder "oidc:${name}:id";
    secret = mkPlaceholder "oidc:${name}:secret";
  }) oidcClients;

  # Substitution table: placeholder string -> file path containing the value.
  secretSubstitutions = lib.mapAttrs' (
    name: s: lib.nameValuePair (mkPlaceholder "secret:${name}") s.path
  ) cfg.runtimeSecrets;

  oidcSubstitutions = lib.concatMapAttrs (name: client: {
    "${mkPlaceholder "oidc:${name}:id"}" = client.id.file;
    "${mkPlaceholder "oidc:${name}:secret"}" = client.secret.file;
  }) oidcClients;

  allSubstitutions = secretSubstitutions // oidcSubstitutions;

  generateBranch = name: s: ''
    echo "Generating ${name}"
    tmp=$(mktemp -p "$(dirname "$path")" .tmp-XXXXXX)
    openssl rand -hex ${toString s.bytes} > "$tmp"
    mv -f "$tmp" "$path"
  '';

  # Best-effort: a non-regenerating secret that's missing is left absent and logged rather than aborting
  # secret generation, so one secret's absence doesn't block the others. Its consumers fail when they read it.
  # (A secret consumed via a runtimeTemplate is the exception: the render below still hard-fails on it.)
  warnMissingBranch = name: ''
    echo "WARNING: ${name} missing at $path and regenerateIfMissing=false; leaving absent." >&2
    echo "  Restore from backup or set regenerateIfMissing=true; consumers of ${name} will fail until then." >&2
  '';

  # Missing-file policy: generate-once, always-regenerate, or never (warn). Generate-once protects a
  # data-bound secret (e.g. an encryption key) — once created it is never silently replaced. Whether the
  # data still exists is read (read-only) from generateOnceGuard when set, else tracked by a `.generated`
  # marker beside the secret: wiping only the secrets dir regenerates cleanly, while a lost secret over
  # surviving data is left absent (restore, don't brick).
  genBranch =
    name: s:
    if s.generateOnce then
      if s.generateOnceGuard != null then
        ''
          if [ -n "$(ls -A ${lib.escapeShellArg s.generateOnceGuard} 2>/dev/null)" ]; then
            echo "WARNING: ${name} is missing but ${s.generateOnceGuard} still holds data it protects; leaving absent." >&2
            echo "  Restore ${name} from backup; a new value would not decrypt the existing data." >&2
          else
            ${generateBranch name s}
          fi
        ''
      else
        ''
          if [ -e "$path.generated" ]; then
            echo "WARNING: ${name} was generated once and is now missing at $path; leaving absent." >&2
            echo "  It protects persistent data — restore it from backup, do not regenerate." >&2
          else
            ${generateBranch name s}
            : > "$path.generated"
          fi
        ''
    else if s.regenerateIfMissing then
      generateBranch name s
    else
      warnMissingBranch name;

  mkSecretScript = name: s: ''
    path=${lib.escapeShellArg s.path}
    ${lib.optionalString (s.migrateFrom != null) ''
      if [ ! -e "$path" ] && [ -e ${lib.escapeShellArg s.migrateFrom} ]; then
        echo "Migrating ${name} from ${s.migrateFrom}"
        cp -p ${lib.escapeShellArg s.migrateFrom} "$path"
      fi
    ''}
    if [ ! -e "$path" ]; then
      ${genBranch name s}
    fi
    if [ -e "$path" ]; then
      chown ${lib.escapeShellArg s.owner}:${lib.escapeShellArg (resolveGroup s)} "$path"
      chmod ${lib.escapeShellArg s.mode} "$path"
    fi
  '';

  # Filter placeholders down to those actually used in the template to avoid
  # opening every secret file on every render (matters when many OIDC clients exist).
  mkTemplateScript =
    name: t:
    let
      relevant = lib.filterAttrs (placeholder: _: lib.hasInfix placeholder t.content) allSubstitutions;
      srcFile = pkgs.writeText "homelab-template-${name}" t.content;
    in
    ''
      echo "Rendering ${name}"
      path=${lib.escapeShellArg t.path}
      install -D -m ${lib.escapeShellArg t.mode} \
        -o ${lib.escapeShellArg t.owner} \
        -g ${lib.escapeShellArg (resolveGroup t)} \
        ${srcFile} "$path"
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (placeholder: filePath: ''
          replace-secret ${lib.escapeShellArg placeholder} ${lib.escapeShellArg filePath} "$path"
        '') relevant
      )}
      if grep -qE '<HOMELAB:[a-f0-9]+:PLACEHOLDER>' "$path"; then
        echo "FATAL: unresolved placeholders in $path" >&2
        exit 1
      fi
    '';

  # OIDC credential files are written (and the secret rotated) at runtime by the provider's
  # per-client provisioning units, which run *after* the provider — which in turn depends on the
  # secrets pass. A template embedding those creds therefore cannot render in the secrets pass
  # (cycle) and must re-render whenever its client re-provisions. Such templates are split into
  # per-client render units bound (after/requires/partOf) to their provisioning unit; everything
  # else renders in the secrets pass, which stays ahead of the provider.
  clientProvisionUnitPrefix = cfg.auth.oidc.systemd.clientProvisionUnitPrefix;
  templateOidcClients =
    t:
    lib.filter (
      name: lib.hasInfix oidcPlaceholderMap.${name}.id t.content || lib.hasInfix oidcPlaceholderMap.${name}.secret t.content
    ) (lib.attrNames oidcClients);
  # Guarded so a missing provider surfaces as the assertion below, not a null-coercion error.
  provisionUnitsFor =
    t:
    lib.optionals (clientProvisionUnitPrefix != null) (
      map (name: "${clientProvisionUnitPrefix}${name}.service") (templateOidcClients t)
    );

  oidcTemplates = lib.filterAttrs (_: t: templateOidcClients t != [ ]) cfg.runtimeTemplates;
  plainTemplates = lib.filterAttrs (_: t: templateOidcClients t == [ ]) cfg.runtimeTemplates;

  renderUnitName = name: "homelab-runtime-template-${lib.replaceStrings [ "." "/" ] [ "-" "-" ] name}";

  secretRestartUnits = lib.unique (lib.concatLists (lib.mapAttrsToList (_: s: s.restartUnits) cfg.runtimeSecrets));
  plainTemplateRestartUnits = lib.unique (lib.concatLists (lib.mapAttrsToList (_: t: t.restartUnits) plainTemplates));

  parentDirsOf = templates: lib.unique (map (t: builtins.dirOf t.path) (lib.attrValues templates));

  # pocket-id (and other secret consumers) depend on this; it must not depend on any OIDC creds.
  mainServiceExists = cfg.runtimeSecrets != { } || plainTemplates != { };
  mainServiceDep = lib.optional mainServiceExists "homelab-runtime-secrets.service";

  # Order a secret/template's consumer units behind whatever renders it.
  mkConsumerDeps =
    generatorUnit: extra: restartUnits:
    lib.listToAttrs (
      map (
        unit:
        lib.nameValuePair (lib.removeSuffix ".service" unit) (
          {
            after = [ generatorUnit ];
            requires = [ generatorUnit ];
          }
          // extra
        )
      ) restartUnits
    );

  secretSubmodule = { name, ... }: {
    options = {
      bytes = lib.mkOption {
        type = lib.types.int;
        default = 32;
        description = "Random bytes (hex-encoded; file is 2x chars).";
      };
      regenerateIfMissing = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Generate a new random value if the file is missing. When false (externally-synced secrets), the file is left absent and logged rather than aborting secret generation; consumers fail until it is restored.";
      };
      generateOnce = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Generate once, then never regenerate (supersedes regenerateIfMissing): a later loss is left absent
          and logged, not silently replaced — for data-bound secrets (e.g. an encryption key). To rotate
          deliberately, remove the secret together with the protected data (or its `.generated` marker).
        '';
      };
      generateOnceGuard = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Path to the data a generate-once secret protects (e.g. a service's data dir). While it exists and is
          non-empty, a missing secret is left absent rather than regenerated. Defaults to null — presence is
          then tracked by a `.generated` marker beside the secret, which a secrets-dir wipe also removes.
        '';
      };
      migrateFrom = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Source path to copy from on first boot if the target is missing (one-time migration; source left in place).";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "Unix owner of the file.";
      };
      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Unix group; defaults to owner's primary group.";
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0400";
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "${secretsDir}/${name}";
        readOnly = true;
      };
      restartUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Units consuming this secret; wired requires+after on the generator (ordering only; values are persistent).";
      };
    };
  };

  templateSubmodule = { name, ... }: {
    options = {
      content = lib.mkOption {
        type = lib.types.lines;
        description = "Template body; reference secrets via runtimePlaceholder.<name> and OIDC creds via oidcPlaceholder.<client>.{id,secret}.";
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "${templatesDir}/${name}";
        description = "Rendered output path (tmpfs; regenerated each boot).";
      };
      owner = lib.mkOption {
        type = lib.types.str;
        default = "root";
      };
      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0400";
      };
      restartUnits = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Units restarted when the template body changes between deploys.";
      };
    };
  };
  renderPath = with pkgs; [
    coreutils
    openssl
    replace-secret
    gnugrep
  ];
  hardening = {
    Type = "oneshot";
    RemainAfterExit = true;
    UMask = "0077";
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
  };
in
{
  options.selfhost = {
    runtimeSecretsDir = lib.mkOption {
      type = lib.types.str;
      default = secretsDir;
      readOnly = true;
      description = "Persistent directory containing runtime-generated secret files. Include in backups.";
    };

    runtimeSecrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule secretSubmodule);
      default = { };
      description = "Runtime-generated secret files (one-shot openssl rand).";
    };

    runtimeTemplates = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule templateSubmodule);
      default = { };
      description = "Templates rendered from runtime secrets and OIDC credentials.";
    };

    runtimePlaceholder = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = secretPlaceholderMap;
      readOnly = true;
      description = "Opaque placeholder string per declared runtime secret.";
    };

    oidcPlaceholder = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption { type = lib.types.str; };
            secret = lib.mkOption { type = lib.types.str; };
          };
        }
      );
      default = oidcPlaceholderMap;
      readOnly = true;
      description = "Opaque placeholder pair per OIDC client.";
    };
  };

  config = lib.mkIf (cfg.runtimeSecrets != { } || cfg.runtimeTemplates != { }) {
    assertions = [
      {
        assertion = oidcTemplates == { } || clientProvisionUnitPrefix != null;
        message = "selfhost.runtimeTemplates referencing oidcPlaceholder require an OIDC provider with selfhost.auth.oidc.systemd.clientProvisionUnitPrefix set (so rendering can be ordered after client provisioning): ${toString (lib.attrNames oidcTemplates)}";
      }
      {
        assertion = lib.all (s: s.generateOnceGuard == null || s.generateOnce) (lib.attrValues cfg.runtimeSecrets);
        message = "selfhost.runtimeSecrets: generateOnceGuard is only consulted when generateOnce = true: ${toString (lib.attrNames (lib.filterAttrs (_: s: s.generateOnceGuard != null && !s.generateOnce) cfg.runtimeSecrets))}";
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${secretsDir} 0755 root root -"
    ]
    ++ lib.optional (cfg.runtimeTemplates != { }) "d ${templatesDir} 0755 root root -";

    systemd.services = lib.mkMerge (
      [
        (lib.optionalAttrs mainServiceExists {
          homelab-runtime-secrets = {
            description = "Generate runtime secrets and render templates";
            wantedBy = [ "multi-user.target" ];
            before = secretRestartUnits ++ plainTemplateRestartUnits;
            path = renderPath;
            serviceConfig = hardening // {
              ReadWritePaths = [ secretsDir ] ++ parentDirsOf plainTemplates;
            };
            script = ''
              set -euo pipefail
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkSecretScript cfg.runtimeSecrets)}
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkTemplateScript plainTemplates)}
            '';
          };
        })
      ]
      # Per-client render units for OIDC-templated env files: bound (partOf) to their provisioning
      # unit so they render after creds exist and re-render on each secret rotation. Consumers are
      # restarted by oidc.nix's dependentServices wiring (also partOf the provisioning unit); this
      # unit only guarantees the re-render lands before that restart.
      ++ (lib.mapAttrsToList (
        name: t:
        let
          provisionUnits = provisionUnitsFor t;
        in
        {
          ${renderUnitName name} = {
            description = "Render runtime template ${name} (OIDC)";
            wantedBy = provisionUnits;
            after = mainServiceDep ++ provisionUnits;
            requires = mainServiceDep ++ provisionUnits;
            partOf = provisionUnits;
            before = t.restartUnits;
            restartTriggers = [ t.content ];
            path = renderPath;
            serviceConfig = hardening // {
              ReadWritePaths = [ (builtins.dirOf t.path) ];
            };
            script = ''
              set -euo pipefail
              ${mkTemplateScript name t}
            '';
          };
        }
      ) oidcTemplates)
      # Consumers order behind their generator: secrets/plain templates behind the secrets pass,
      # OIDC templates behind their per-client render unit (templates also restart on body changes).
      ++ (lib.mapAttrsToList (_: s: mkConsumerDeps "homelab-runtime-secrets.service" { } s.restartUnits) cfg.runtimeSecrets)
      ++ (lib.mapAttrsToList (
        _: t: mkConsumerDeps "homelab-runtime-secrets.service" { restartTriggers = [ t.content ]; } t.restartUnits
      ) plainTemplates)
      ++ (lib.mapAttrsToList (
        name: t: mkConsumerDeps "${renderUnitName name}.service" { restartTriggers = [ t.content ]; } t.restartUnits
      ) oidcTemplates)
    );
  };
}
