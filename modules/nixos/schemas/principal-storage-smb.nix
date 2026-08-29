# Per-principal SMB surface, shared by `selfhost.users` and `selfhost.serviceAccounts`: a person and a
# machine hold an account on the same terms. Holding an account is separate from being let into a share;
# grants live on the share, where the whole access list reads at once.
{ lib, ... }:
{
  options.storage.smb = {
    enable = lib.mkEnableOption "an SMB account for this principal on a host serving `selfhost.storage.shares.smb`";

    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "File holding this principal's SMB password, read at activation through a credential and never placed in the store. Required once `enable` is set.";
    };
  };
}
