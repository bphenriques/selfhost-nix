# Per-principal SMB surface, shared by `selfhost.users` and `selfhost.serviceAccounts`: a person and a
# machine hold an account on the same terms. Holding an account is separate from being let into a share;
# grants live on the share, where the whole access list reads at once.
{ options, lib, ... }:
{
  options.storage.smb = {
    enable = lib.mkEnableOption "an SMB account for this principal on a host serving `selfhost.storage.shares.smb`";

    passwordFile = lib.mkOption {
      type = lib.types.str;
      description = "File holding this principal's SMB password, read at activation through a credential and never placed in the store. Required once `enable` is set.";
    };

    hasPassword = lib.mkOption {
      type = lib.types.bool;
      readOnly = true;
      internal = true;
      default = options.storage.smb.passwordFile.isDefined;
      defaultText = lib.literalMD "whether `passwordFile` has been set";
      description = "Whether this principal supplied a password. Exposed because a per-element option inside an `attrsOf submodule` cannot be probed for `isDefined` from outside it, which is what `storage/shares.nix` needs to assert.";
    };
  };
}
