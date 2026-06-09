# Registry of externally-defined systemd units (timers, oneshots, maintenance jobs) that opt into
# selfhost cross-cutting concerns. It does not create or schedule units — define those with
# systemd.services/systemd.timers as usual, then list them here so notify-on-failure (notify.nix)
# and storage mounts (smb.nix) attach to them. Schema composed from the fragments in schemas/.
{ lib, config, ... }:
let
  cfg = config.selfhost;

  baseTaskModule =
    { name, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Task identifier (defaults to the attribute name).";
        };

        systemdServices = lib.mkOption {
          type = lib.types.coercedTo lib.types.str (s: [ s ]) (lib.types.listOf lib.types.str);
          default = [ ];
          description = "Systemd units this task owns; selfhost concerns attach to them.";
        };
      };
    };
in
{
  options.selfhost.tasks = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submoduleWith {
        specialArgs = {
          selfhostCfg = cfg;
        };
        modules = [
          baseTaskModule
          ./schemas/notify.nix
          ./schemas/task-storage.nix
        ];
      }
    );
    default = { };
    description = "Registry of externally-defined systemd units that opt into selfhost concerns (notify, storage).";
  };
}
