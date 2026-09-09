# shellcheck shell=bash

# No principals means no LoadCredential and no $CREDENTIALS_DIRECTORY. Globbing an unset one yields
# /*, which would try to mint an account per root directory, so skip the loop instead of expanding it.
shopt -s nullglob

declared=""
if [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
  for credential in "$CREDENTIALS_DIRECTORY"/*; do
    account="$(basename "$credential")"
    declared+=" $account"
    password="$(cat "$credential")"
    printf '%s\n%s\n' "$password" "$password" | smbpasswd -a -s "$account"
  done
fi

# Say so out loud: the pass below then revokes every account, which is right but drastic enough that it
# should not happen quietly.
if [ -z "$declared" ]; then
  echo "No SMB principals declared; revoking every account in the passdb." >&2
fi

# The passdb is generated, so an account that is no longer declared is a credential nobody revoked.
pdbedit -L | cut -d: -f1 | while read -r account; do
  case " $declared " in
    *" $account "*) ;;
    *) smbpasswd -x "$account" ;;
  esac
done
