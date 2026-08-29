{ lib, config, ... }:
let
  cfg = config.selfhost;

  adminUsers = lib.filterAttrs (_: u: u.isAdmin) cfg.users;

  baseUserModule = { name, config, ... }: {
    options = {
      username = lib.mkOption {
        type = lib.types.str;
        default = name;
        defaultText = lib.literalMD "the attribute name";
        description = "Login name used by the services this user is enabled on.";
      };
      email = lib.mkOption {
        type = lib.types.str;
        # Not enforced unique: guest/ad-hoc users may share placeholder emails.
        description = "Email address, used by services that identify accounts by one (OIDC, Gitea, Immich).";
      };
      firstName = lib.mkOption {
        type = lib.types.str;
        description = "Given name, used to build `name` and by services that store it separately.";
      };
      lastName = lib.mkOption {
        type = lib.types.str;
        description = "Family name, used to build `name` and by services that store it separately.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "${config.firstName} ${config.lastName}";
        defaultText = lib.literalMD "`<firstName> <lastName>`";
        description = "Display name shown by services that take a single full name.";
      };
      groups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Groups assigned to this user. If admin group is included, the user is marked as admin.";
      };
      isAdmin = lib.mkOption {
        type = lib.types.bool;
        readOnly = true;
        default = lib.elem cfg.groups.admin config.groups;
        defaultText = lib.literalMD "true if the user's `groups` include the admin group";
        description = "Whether this user is an admin (derived from `groups`; set the group, not this).";
      };
      extraConfig = lib.mkOption {
        type = lib.types.submodule { freeformType = lib.types.attrsOf lib.types.anything; };
        default = { };
        description = "Consumer-owned per-user data with no first-class option; selfhost-nix never reads it. Per-service config mirrors the registry at `users.<name>.services.<name>`, not here. Read back at `config.selfhost.users.<name>.extraConfig`.";
      };
    };
  };
in
{
  options.selfhost = {
    groups = {
      admin = lib.mkOption {
        type = lib.types.str;
        default = "admin";
        description = "Name of the admin group";
      };

      users = lib.mkOption {
        type = lib.types.str;
        default = "users";
        description = "Name of the users group";
      };

      guests = lib.mkOption {
        type = lib.types.str;
        default = "guests";
        description = "Name of the guests group";
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule [
          baseUserModule
          ./schemas/user-oidc.nix
        ]
      );
      default = { };
      description = ''
        People, keyed by username. Non-human principals belong in `selfhost.serviceAccounts`: this
        schema requires a name and an email and layers OIDC onto every entry, which a robot has
        neither of. Per-service config mirrors the registry at `users.<name>.services.<service>`; a
        concern's per-user opt-in mirrors the concern, e.g. `users.<name>.auth.oidc.enable`. One admin
        is required once any service is registered.
      '';
    };
  };

  # At least one admin (someone must reach admin-gated services); more is a consumer choice. A host that
  # registers no services has nothing to gate, so it needs none: same shape as the ingress.domain
  # assertion. The admin group's name stays configurable via selfhost.groups.admin.
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.services == { } || adminUsers != { };
        message = "At least one user must be in the admin group (selfhost.groups.admin); none found.";
      }
    ];
  };
}
