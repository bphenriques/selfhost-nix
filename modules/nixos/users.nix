{ lib, config, ... }:
let
  cfg = config.selfhost;

  adminUsers = lib.filterAttrs (_: u: u.isAdmin) cfg.users;

  baseUserModule = { name, config, ... }: {
    options = {
      username = lib.mkOption {
        type = lib.types.str;
        default = name;
      };
      email = lib.mkOption { type = lib.types.str; }; # Not enforced unique: guest/ad-hoc users may share placeholder emails
      firstName = lib.mkOption { type = lib.types.str; };
      lastName = lib.mkOption { type = lib.types.str; };
      name = lib.mkOption {
        type = lib.types.str;
        default = "${config.firstName} ${config.lastName}";
        defaultText = lib.literalMD "`<firstName> <lastName>`";
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
    };

    adminUser = lib.mkOption {
      type = lib.types.unspecified;
      readOnly = true;
      description = "The single admin user (derived from users with the admin group).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.length (lib.attrNames adminUsers) == 1;
        message = "Exactly one admin user must exist, but found ${toString (lib.length (lib.attrNames adminUsers))}: ${toString (lib.attrNames adminUsers)}";
      }
    ];

    selfhost.adminUser = lib.head (lib.attrValues adminUsers);
  };
}
