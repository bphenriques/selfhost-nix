# Small build helpers shared by modules. Imported directly (not via the overlay) so modules usable
# standalone — without nixosModules.default and its overlay — can still call them.
{ pkgs, lib }:
{
  # An executable `name` that runs a nu-checked nushell `script` with `runtimeInputs` (plus nushell) on PATH.
  writeNushellApplication =
    {
      name,
      runtimeInputs ? [ ],
      script,
    }:
    let
      checked = pkgs.runCommandLocal "${name}.nu" { } ''
        ${lib.getExe pkgs.nushell} --no-config-file --commands 'if not (nu-check "${script}") { exit 1 }'
        cp ${script} $out
      '';
    in
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.nushell ] ++ runtimeInputs;
      text = ''exec nu ${checked} "$@"'';
    };
}
