# WireGuard's per-user surface (devices), kept beside the module rather than in core's user schema.
{ lib, ... }:
{
  options.selfhost.users = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options.apps.wireguard = {
          enable = lib.mkEnableOption "WireGuard configuration for this user";
          devices = lib.mkOption {
            type = lib.types.listOf (
              lib.types.submodule {
                options = {
                  name = lib.mkOption {
                    type = lib.types.strMatching "[a-z0-9][a-z0-9-]*";
                    description = "Device name (e.g. phone, laptop). Lowercase alphanumeric and dashes only.";
                  };
                  ip = lib.mkOption {
                    type = lib.types.str;
                    description = "Static WireGuard client IP (e.g. 10.100.0.42).";
                  };
                  publicKey = lib.mkOption {
                    type = lib.types.str;
                    description = "Device's WireGuard public key, from `wg-manage add` (the private key stays on the server).";
                  };
                  fullAccess = lib.mkOption {
                    type = lib.types.bool;
                    default = false;
                    description = "If true, device can reach the whole LAN; if false, only the home server.";
                  };
                };
              }
            );
            default = [ ];
            description = "WireGuard devices for this user.";
          };
        };
      }
    );
  };
}
