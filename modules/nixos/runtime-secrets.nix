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

  # Readable rather than hashed, so the unresolved-placeholder check can name what failed.
  mkPlaceholder = key: "<HOMELAB:${key}:PLACEHOLDER>";

  secretPlaceholderMap = lib.mapAttrs (name: _: mkPlaceholder "secret:${name}") cfg.runtimeSecrets;

  oidcClients = cfg.auth.oidc.clients or { };
  oidcPlaceholderMap = lib.mapAttrs (name: _: {
    id = mkPlaceholder "oidc:${name}:id";
    secret = mkPlaceholder "oidc:${name}:secret";
  }) oidcClients;

  # Derived from the maps above, never rebuilt: two constructions of one placeholder can drift silently.
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

  # Logged rather than fatal, so one missing secret doesn't block the rest. A template using it still fails.
  warnMissingBranch = name: ''
    echo "WARNING: ${name} missing at $path and onMissing = \"warn\"; leaving absent." >&2
    echo "  Restore it from backup; consumers of ${name} will fail until then." >&2
  '';

  guardedBranch = name: s: guard: ''
    if [ -n "$(ls -A ${lib.escapeShellArg guard} 2>/dev/null)" ]; then
      echo "WARNING: ${name} is missing but ${guard} still holds data it protects; leaving absent." >&2
      echo "  Restore ${name} from backup; a new value would not decrypt the existing data." >&2
    else
      ${generateBranch name s}
    fi
  '';

  genBranch =
    name: s:
    if s.onMissing == "regenerate" then
      generateBranch name s
    else if s.onMissing == "warn" then
      warnMissingBranch name
    else
      guardedBranch name s s.onMissing.generateOnce;

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

  # Only the placeholders this template uses, so a render doesn't open every secret file.
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

  # One render unit per template: OIDC credentials appear only after the secrets pass, so it can't render them.
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

  # Only `/` is folded (`.` is legal in unit names); the resulting collisions are asserted below.
  renderUnitName = name: "homelab-runtime-template-${lib.replaceStrings [ "/" ] [ "-" ] name}";

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
      onMissing = lib.mkOption {
        type =
          lib.types.either
            (lib.types.enum [
              "regenerate"
              "warn"
            ])
            (
              lib.types.submodule {
                options.generateOnce = lib.mkOption {
                  type = lib.types.str;
                  description = "Data this secret protects; while it is non-empty, a missing secret stays absent. List the unit that creates it in `restartUnits`.";
                };
              }
            );
        default = "regenerate";
        example = {
          generateOnce = "/var/lib/pocket-id";
        };
        description = "When the file is missing: generate a new value, warn and leave it absent, or generate only while the guarded data is empty.";
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

  # Admin inventory, built from the options the generators read so the CLI can flag drift on disk.
  oidcProvisionUnit =
    client: if clientProvisionUnitPrefix == null then null else "${clientProvisionUnitPrefix}${client}.service";
  notifyPublishers = lib.filterAttrs (_: p: p.integrations.notify.enable) (cfg.services // cfg.tasks);
  # Grouping only: the longest service name prefixing a secret. Tasks are left out so `sonarr-configure` files under sonarr.
  appCandidates = lib.sort (a: b: lib.stringLength a > lib.stringLength b) (
    lib.unique (lib.attrNames cfg.services ++ [ "smb" ])
  );
  appOf = fallback: name: lib.findFirst (candidate: lib.hasPrefix candidate name) fallback appCandidates;

  manifest =
    lib.mapAttrsToList (name: s: {
      app = appOf "other" name;
      inherit name;
      inherit (s) path;
      kind = "secret";
      unit = "homelab-runtime-secrets.service";
      expected = {
        inherit (s) owner mode;
        group = resolveGroup s;
      };
    }) cfg.runtimeSecrets
    ++ lib.mapAttrsToList (name: t: {
      app = appOf "other" name;
      inherit name;
      inherit (t) path;
      kind = "template";
      unit = "${renderUnitName name}.service";
      expected = {
        inherit (t) owner mode;
        group = resolveGroup t;
      };
    }) cfg.runtimeTemplates
    # Owner and mode are constants in pocket-id-manage, so there is nothing to compare here.
    ++ lib.concatMap (client: [
      {
        app = client;
        name = "oidc/${client}/id";
        path = oidcClients.${client}.id.file;
        kind = "oidc";
        unit = oidcProvisionUnit client;
        expected = null;
      }
      {
        app = client;
        name = "oidc/${client}/secret";
        path = oidcClients.${client}.secret.file;
        kind = "oidc";
        unit = oidcProvisionUnit client;
        expected = null;
      }
    ]) (lib.attrNames oidcClients)
    ++ lib.mapAttrsToList (publisher: p: {
      # Falls back to its own name, so a task's token files under the app it reconciles.
      app = appOf publisher publisher;
      name = "notify/${publisher}";
      path = p.integrations.notify.tokenFile;
      kind = "token";
      unit = cfg.notify.provisioningUnit;
      expected = null;
    }) notifyPublishers;

  manifestFile = pkgs.writeText "homelab-secrets-manifest.json" (builtins.toJSON manifest);

  homelabSecrets = pkgs.writeShellApplication {
    name = "homelab-secrets";
    runtimeInputs = [ pkgs.selfhost.homelab-secrets ];
    text = ''
      export HOMELAB_SECRETS_MANIFEST=${manifestFile}
      exec homelab-secrets-bin "$@"
    '';
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
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
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

        # Names the colliding templates, which the module system's `description` conflict would not.
        unitCollisions = lib.filterAttrs (_: names: lib.length names > 1) (
          builtins.groupBy renderUnitName (lib.attrNames cfg.runtimeTemplates)
        );

        # `homelab-secrets cat` takes one name, so names must be unique across secrets and templates.
        nameCollisions = lib.filterAttrs (_: entries: lib.length entries > 1) (builtins.groupBy (e: e.name) manifest);
      in
      [
        {
          assertion = needProvider == [ ] || clientProvisionUnitPrefix != null;
          message = "selfhost.runtimeTemplates referencing oidcPlaceholder require an OIDC provider with selfhost.auth.oidc.systemd.clientProvisionUnitPrefix set (so rendering can be ordered after client provisioning): ${toString needProvider}";
        }
        {
          assertion = unitCollisions == { };
          message = "Templates whose names collapse to one render unit: ${
            lib.concatStringsSep "; " (
              lib.mapAttrsToList (unit: names: "${unit} ← ${lib.concatStringsSep ", " names}") unitCollisions
            )
          }. Rename one, since a unit can only render a single template.";
        }
        {
          assertion = nameCollisions == { };
          message = "Secrets sharing one name, which `homelab-secrets cat` could not tell apart: ${
            lib.concatStringsSep "; " (
              lib.mapAttrsToList (name: entries: "${name} ← ${lib.concatStringsSep ", " (map (e: e.path) entries)}") nameCollisions
            )
          }. Rename one.";
        }
      ];

    # Read-only, no setuid and no group grant: a convenience over `sudo cat`, which the admin already has.
    environment.systemPackages = [ homelabSecrets ];

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
      # partOf the embedded clients' provisioning, so a re-provision re-renders it.
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
      ++ (lib.mapAttrsToList (_: s: mkConsumerDeps "homelab-runtime-secrets.service" { } s.restartUnits) cfg.runtimeSecrets)
      ++ (lib.mapAttrsToList (
        name: t: mkConsumerDeps "${renderUnitName name}.service" { restartTriggers = [ t.content ]; } t.restartUnits
      ) cfg.runtimeTemplates)
    );
  };
}
