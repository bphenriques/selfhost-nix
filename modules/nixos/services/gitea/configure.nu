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
  let body = {admin: $is_admin, login_name: $login_name, source_id: $user.source_id}
  let r = http patch $"($base_url)/api/v1/admin/users/($user.login)" $body --content-type application/json --headers { Authorization: $"token ($token)" } --full --allow-errors
  if $r.status != 200 {
    error make {msg: $"($user.login): failed to set admin=($is_admin): ($r.status) - ($r.body)"}
  }
  print $"  ($user.login): admin=($is_admin)"
}

# Public keys currently registered for a user (no token needed).
def user_keys [username: string] {
  let r = http get $"($base_url)/api/v1/users/($username)/keys" --full --allow-errors
  if $r.status != 200 {
    error make {msg: $"($username): failed to list ssh keys: ($r.status) - ($r.body)"}
  }
  $r.body | each {|k| $k.key }
}

# Add-only: register one public key for a user (the caller diffs against user_keys for idempotency).
def add_key [username: string, key: record, token: string] {
  let title = $"($username)-($key.key | hash md5 | str substring 0..8)"
  let body = {key: $key.key, title: $title, read_only: $key.readOnly}
  let r = http post $"($base_url)/api/v1/admin/users/($username)/keys" $body --content-type application/json --headers { Authorization: $"token ($token)" } --full --allow-errors
  if $r.status != 201 {
    error make {msg: $"($username): failed to add ssh key: ($r.status) - ($r.body)"}
  }
  print $"  ($username): ssh key registered"
}

# Usernames from the CLI listing (no token needed). Column 1 is the username; the header row is skipped.
def list_usernames [--admin] {
  let r = if $admin {
    gitea $config_flag admin user list --admin | complete
  } else {
    gitea $config_flag admin user list | complete
  }
  $r.stdout
  | str trim
  | lines
  | skip 1
  | each {|line| ($line | split row " " | where ($it | str length) > 0) | get 1? | default "" }
  | where ($it | is-not-empty)
}

# Creates the account if missing (admin status and SSH keys are reconciled separately, in main).
def ensure_user [user: record, existing: list<string>] {
  if $user.username in $existing { return }
  let password = (random chars --length 32)
  gitea $config_flag admin user create --username $user.username --password $password --email $user.email --must-change-password=false
  print $"Created user '($user.username)'"
}

# The OIDC auth source is provisioned separately, before gitea starts (see oidc-source.nu); everything here
# needs the running server (API for keys/admin-status) or is cheap to do post-start (admin, user accounts).
def main [] {
  wait_ready
  print "Gitea is ready"
  ensure_admin

  # Create any missing accounts first (no token needed), so the keys endpoint below is valid for every user.
  let existing = list_usernames
  for u in $users { ensure_user $u $existing }

  # Detect work token-free (CLI admin list + the public keys endpoint), then mint the ephemeral admin token
  # only on a real delta — a missing SSH key or an admin-status change — so a steady-state run touches nothing.
  let current_admins = list_usernames --admin
  let missing_keys = $users | each {|u|
    let desired = $u.sshKeys? | default []
    if ($desired | is-empty) { [] } else {
      let present = user_keys $u.username
      $desired | where {|k| $k.key not-in $present } | each {|k| { username: $u.username, key: $k } }
    }
  } | flatten
  let needs_admin = $users | any {|u| ($u.isAdmin? | default false) != ($u.username in $current_admins) }
  let tok = if ($missing_keys | is-not-empty) or $needs_admin { admin_token } else { null }

  if $tok != null {
    let token = $tok.token

    # SSH keys: add the missing ones (add-only — existing and out-of-band keys are left untouched).
    for m in $missing_keys { add_key $m.username $m.key $token }

    # Admin: reconcile against the live records (now including just-created users); PATCH only on a delta,
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
