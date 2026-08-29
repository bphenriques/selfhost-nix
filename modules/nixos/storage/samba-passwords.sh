# shellcheck shell=bash

declared=""
for credential in "$CREDENTIALS_DIRECTORY"/*; do
  account="$(basename "$credential")"
  declared+=" $account"
  password="$(cat "$credential")"
  printf '%s\n%s\n' "$password" "$password" | smbpasswd -a -s "$account"
done

# The passdb is generated, so an account that is no longer declared is a credential nobody revoked.
pdbedit -L | cut -d: -f1 | while read -r account; do
  case " $declared " in
    *" $account "*) ;;
    *) smbpasswd -x "$account" ;;
  esac
done
