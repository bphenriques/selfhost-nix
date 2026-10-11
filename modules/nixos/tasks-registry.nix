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
          default = [ name ];
          defaultText = lib.literalMD "`<name>`";
          description = "Systemd units this task owns; selfhost concerns attach to them (storage automount guards, failure notifications). Names are trusted, not checked.";
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
          # Every task has a failure worth hearing about and the hook reporting it is the framework's, so
          # notify.defaultTopic applies. A service is the other way round: its notifications are domain
          # events it sends itself, and most have none, so those name a topic one at a time.
          notifyDefaultTopic = cfg.notify.defaultTopic;
        };
        modules = [
          baseTaskModule
          ./schemas/notify.nix
          ./schemas/storage.nix
        ];
      }
    );
    default = { };
    description = "Registry of externally-defined systemd units that opt into selfhost concerns (notify, storage).";
  };
}
