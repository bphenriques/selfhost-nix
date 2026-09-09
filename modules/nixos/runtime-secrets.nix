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

  # Readable, not hashed: the key is an option name, which is already public, and hashing it only meant
  # the unresolved-placeholder check below could say *that* something failed to substitute but never
  # *what*. The delimiters are what keep it from colliding with real config content.
  mkPlaceholder = key: "<HOMELAB:${key}:PLACEHOLDER>";

  secretPlaceholderMap = lib.mapAttrs (name: _: mkPlaceholder "secret:${name}") cfg.runtimeSecrets;

  oidcClients = cfg.auth.oidc.clients or { };
  oidcPlaceholderMap = lib.mapAttrs (name: _: {
    id = mkPlaceholder "oidc:${name}:id";
    secret = mkPlaceholder "oidc:${name}:secret";
  }) oidcClients;

  # Substitution table: placeholder string -> file path containing the value. Derived from the maps
  # above rather than rebuilding the placeholder from its key a second time: two constructions of the
  # same string can drift, and the failure is silent — the template renders with nothing substituted.
  secretSubstitutions = lib.mapAttrs' (
    name: placeholder: lib.nameValuePair placeholder cfg.runtimeSecrets.${name}.path
  ) secretPlaceholderMap;

  oidcSubstitutions = lib.concatMapAttrs (name: placeholder: {
    ${placeholder.id} = oidcClients.${name}.id.file;
    ${placeholder.secret} = oidcClients.${name}.secret.file;
  }) oidcPlaceholderMap;

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
  # data-bound secret (e.g. an encryption key) — once created it is never silently replaced. Its option
  # value *is* the guard path, so a lost secret over surviving data is left absent (restore, don't
  # brick), and regenerates once that data is gone.
  genBranch =
    name: s:
    if s.generateOnce != null then
      ''
        if [ -n "$(ls -A ${lib.escapeShellArg s.generateOnce} 2>/dev/null)" ]; then
          echo "WARNING: ${name} is missing but ${s.generateOnce} still holds data it protects; leaving absent." >&2
          echo "  Restore ${name} from backup; a new value would not decrypt the existing data." >&2
        else
          ${generateBranch name s}
        fi
      ''
    else if s.regenerateIfMissing then
      generateBranch name s
    else
      warnMissingBranch name;

  mkSecretScript = name: s: ''
    path=${lib.escapeShellArg s.path}
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
      if grep -qE '<HOMELAB:[^>]*:PLACEHOLDER>' "$path"; then
        echo "FATAL: unresolved placeholders in $path:" >&2
        grep -oE '<HOMELAB:[^>]*:PLACEHOLDER>' "$path" | sort -u >&2
        exit 1
      fi
    '';

  # Every template renders in a unit named after it, whether or not it embeds OIDC credentials. Those
  # credentials are written at runtime by the provider's per-client provisioning units, which run after
  # the provider, which depends on the secrets pass — so a template embedding them cannot render in the
  # secrets pass (cycle) and must re-render on each re-provision. Giving *all* templates that shape
  # rather than only the ones that need it keeps one render path: which unit renders a template follows
  # from its name, not from whether its content happens to mention a client.
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

  renderUnitName = name: "homelab-runtime-template-${lib.replaceStrings [ "." "/" ] [ "-" "-" ] name}";

  # pocket-id (and other secret consumers) depend on this; it must not depend on any OIDC creds.
  mainServiceExists = cfg.runtimeSecrets != { };
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
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/var/lib/pocket-id";
        description = ''
          Path to the data this secret protects (e.g. a service's data dir), which makes it generate-once:
          created if absent, then never silently replaced (this supersedes `regenerateIfMissing`). For
          data-bound secrets such as an encryption key, where a fresh value would orphan what it opened.

          The path is the guard. While it exists and is non-empty, a missing secret is left absent and
          logged — restore it rather than letting a rebuild manufacture a new one. A wiped host with no
          data to orphan generates cleanly. To rotate deliberately, remove the secret together with the
          data. `null` means this is an ordinary regenerable secret.

          The unit that creates this path must be listed in `restartUnits`, which is what orders it after
          the generator. Without that ordering it can populate the path first, and the guard then
          suppresses the very first generation, permanently and silently.
        '';
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
        description = "File mode (octal) of the secret file.";
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "${secretsDir}/${name}";
        defaultText = lib.literalMD "`${secretsDir}/<name>`";
        readOnly = true;
        description = "Where this secret is generated; read it to feed a consumer that wants a file path.";
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
        description = "Unix owner of the rendered file.";
      };
      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Unix group; defaults to owner's primary group.";
      };
      mode = lib.mkOption {
        type = lib.types.str;
        default = "0400";
        description = "File mode (octal) of the rendered file.";
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
            id = lib.mkOption {
              type = lib.types.str;
              description = "Placeholder standing in for this client's OIDC client ID.";
            };
            secret = lib.mkOption {
              type = lib.types.str;
              description = "Placeholder standing in for this client's OIDC client secret.";
            };
          };
        }
      );
      default = oidcPlaceholderMap;
      readOnly = true;
      description = "Opaque placeholder pair per OIDC client.";
    };
  };

  config = lib.mkIf (cfg.runtimeSecrets != { } || cfg.runtimeTemplates != { }) {
    assertions =
      let
        needProvider = lib.attrNames (lib.filterAttrs (_: t: templateOidcClients t != [ ]) cfg.runtimeTemplates);
      in
      [
        {
          assertion = needProvider == [ ] || clientProvisionUnitPrefix != null;
          message = "selfhost.runtimeTemplates referencing oidcPlaceholder require an OIDC provider with selfhost.auth.oidc.systemd.clientProvisionUnitPrefix set (so rendering can be ordered after client provisioning): ${toString needProvider}";
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
            description = "Generate runtime secrets";
            wantedBy = [ "multi-user.target" ];
            path = renderPath;
            serviceConfig = hardening // {
              ReadWritePaths = [ secretsDir ];
            };
            script = ''
              set -euo pipefail
              ${lib.concatStringsSep "\n" (lib.mapAttrsToList mkSecretScript cfg.runtimeSecrets)}
            '';
          };
        })
      ]
      # One render unit per template. It waits on the secrets pass, and additionally on the provisioning
      # units of any OIDC client it embeds — `partOf` those, so a re-provision re-renders it. `wantedBy`
      # multi-user.target so it renders at boot even when nothing lists it in `restartUnits`, which is
      # what keeps a consumer from ever starting against an unrendered file.
      ++ (lib.mapAttrsToList (
        name: t:
        let
          provisionUnits = provisionUnitsFor t;
        in
        {
          ${renderUnitName name} = {
            description = "Render runtime template ${name}";
            wantedBy = [ "multi-user.target" ] ++ provisionUnits;
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
      ) cfg.runtimeTemplates)
      # Consumers order behind whatever produces what they read: a secret behind the secrets pass, a
      # template behind its own render unit (and restarting when the body changes between deploys).
      ++ (lib.mapAttrsToList (_: s: mkConsumerDeps "homelab-runtime-secrets.service" { } s.restartUnits) cfg.runtimeSecrets)
      ++ (lib.mapAttrsToList (
        name: t: mkConsumerDeps "${renderUnitName name}.service" { restartTriggers = [ t.content ]; } t.restartUnits
      ) cfg.runtimeTemplates)
    );
  };
}
