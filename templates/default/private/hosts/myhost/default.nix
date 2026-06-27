# Per-host private bundle consumed as `private.hosts.<name>` by the public flake.
{
  settings = import ./settings.nix;
  sopsSecretsFile = ./secrets.yaml;
}
