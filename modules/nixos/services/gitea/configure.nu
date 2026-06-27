#!/usr/bin/env nu
# Gitea post-start setup: admin, user accounts, and service-account SSH keys (admin API + an ephemeral
# token). The OIDC auth source is provisioned separately, before the server starts (oidc-source.nu).
let base_url = $env.GITEA_URL
let config_flag = $"-c=($env.GITEA_CONFIG)"
let admin_password = open $env.GITEA_ADMIN_PASSWORD_FILE | str trim
let users = open $env.GITEA_USERS_FILE

def wait_ready [] {
  for attempt in 1..60 {
    print $"Waiting for Gitea... ($attempt)"
    try {
      http get $"($base_url)/api/healthz" --max-time 2sec | ignore
      return
    } catch { sleep 2sec }
  }
  error make {msg: "Gitea failed to start after 60 attempts"}
}

def ensure_admin [] {
  let r = gitea $config_flag admin user list --admin | complete
  if $r.exit_code != 0 or ($r.stdout | str trim | lines | length) <= 1 {
    gitea $config_flag admin user create --admin --username admin --password $admin_password --email "admin@localhost" --must-change-password=false
    print "Admin user created"
  } else {
    # Reconcile so the runtime secret stays the source of truth (a regenerated file self-heals).
    gitea $config_flag admin user change-password --username admin --password $admin_password --must-change-password=false
    print "Admin password reconciled"
  }
}

# Mint an ephemeral admin API token (the CLI can't add SSH keys); revoked at end of run.
def admin_token [] {
  let name = $"gitea-configure-(random chars --length 8)"
  let r = gitea $config_flag admin user generate-access-token --username admin --scopes write:admin --token-name $name | complete
  if $r.exit_code != 0 { error make {msg: $"Failed to mint admin token: ($r.stderr)"} }
  {
    name: $name
    token: ($r.stdout | parse --regex '(?<t>[0-9a-f]{40})' | get t.0)
  }
}

def revoke_token [tok: record] {
  http delete $"($base_url)/api/v1/users/admin/tokens/($tok.name)" --headers { Authorization: $"token ($tok.token)" } --allow-errors | ignore
}

# Full user records — the API exposes login_name/source_id (which the admin PATCH needs), the CLI doesn't.
def get_users_api [token: string] {
  let r = http get $"($base_url)/api/v1/admin/users?limit=50" --headers { Authorization: $"token ($token)" } --full --allow-errors
  if $r.status != 200 { error make {msg: $"Failed to list users: ($r.status) - ($r.body)"} }
  $r.body
}

# Promote/demote via the admin API (no CLI toggle). gitea requires a non-empty login_name + source_id even
# for one field: echo the real source_id (keeps an OIDC-linked source); fall back to username when empty.
def set_admin [user: record, is_admin: bool, token: string] {
  let login_name = if ($user.login_name | is-empty) { $user.login } else { $user.login_name }
  let body = { admin: $is_admin, login_name: $login_name, source_id: $user.source_id }
  let r = http patch $"($base_url)/api/v1/admin/users/($user.login)" $body --content-type application/json --headers { Authorization: $"token ($token)" } --full --allow-errors
  if $r.status != 200 {
    print $"  ($user.login): admin=($is_admin) failed ($r.status) - ($r.body)"
  } else {
    print $"  ($user.login): admin=($is_admin)"
  }
}

def register_keys [username: string, ssh_keys: list<any>, token: string] {
  for k in $ssh_keys {
    let title = $"($username)-($k.key | hash md5 | str substring 0..8)"
    let body = {key: $k.key, title: $title, read_only: $k.readOnly}
    let r = http post $"($base_url)/api/v1/admin/users/($username)/keys" $body --content-type application/json --headers { Authorization: $"token ($token)" } --full --allow-errors
    if $r.status != 201 {
      print $"  ($username): key add failed ($r.status) - ($r.body)"
    } else {
      print $"  ($username): ssh key registered"
    }
  }
}

# Creates the account if missing (admin status is reconciled separately; password/keys stay user-owned after).
def ensure_user [user: record, token] {
  let listing = (gitea $config_flag admin user list | complete).stdout | str trim | lines | skip 1
  let exists = $listing | any {|line| (($line | split row " " | where ($it | str length) > 0) | get 1? | default "") == $user.username }
  if $exists { return }
  let password = (random chars --length 32)
  gitea $config_flag admin user create --username $user.username --password $password --email $user.email --must-change-password=false
  print $"Created user '($user.username)'"
  let keys = $user.sshKeys? | default []
  if ($keys | is-not-empty) { register_keys $user.username $keys $token }
}

# The OIDC auth source is provisioned separately, before gitea starts (see oidc-source.nu); everything here
# needs the running server (API for keys/admin-status) or is cheap to do post-start (admin, user accounts).
def main [] {
  wait_ready
  print "Gitea is ready"
  ensure_admin

  # Admin reconcile and key registration both need the API, so mint a token whenever there are accounts to
  # reconcile or keys to add. (Token minting needs the admin, created above.)
  let needs_keys = $users | any {|u| (($u.sshKeys? | default []) | is-not-empty) }
  let tok = if ($needs_keys or ($users | is-not-empty)) { admin_token } else { null }
  let token = if $tok != null { $tok.token } else { "" }

  for u in $users { ensure_user $u $token }

  if $tok != null {
    # Reconcile admin against the live records (now including just-created users); PATCH only on a delta,
    # echoing the record's login_name/source_id so the auth source is left intact.
    let records = get_users_api $token
    for u in $users {
      let want = $u.isAdmin? | default false
      let rec = $records | where login == $u.username | get 0?
      if $rec != null and $rec.is_admin != $want { set_admin $rec $want $token }
    }
    revoke_token $tok
    print "Revoked ephemeral admin token"
  }
  print "Gitea configuration complete"
}
