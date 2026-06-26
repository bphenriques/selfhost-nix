#!/usr/bin/env nu
# Configures Gitea: admin user, OIDC auth source, and declared accounts. Human/bot accounts are created
# via the stable `gitea admin` CLI; service-account SSH keys are registered through the admin API (the
# CLI has no key command), authed with an ephemeral admin token this script mints.
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

# Mint an admin API token (CLI can't add SSH keys; basic auth is disabled). Ephemeral: revoked at the end
# of the run (see revoke_token), so nothing accumulates on the admin account. Unique name avoids collisions.
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

# Usernames currently flagged site-admin (the local `admin` superuser plus any promoted accounts).
def current_admins [] {
  let r = gitea $config_flag admin user list --admin | complete
  if $r.exit_code != 0 { return [] }
  $r.stdout | str trim | lines | skip 1 | each {|line|
    $line | split row " " | where ($it | str length) > 0 | get 1? | default ""
  } | where ($it | is-not-empty)
}

# Promote/demote an existing account to match declared intent (the CLI has no admin toggle, so use the API).
def set_admin [username: string, is_admin: bool, token: string] {
  let r = http patch $"($base_url)/api/v1/admin/users/($username)" {admin: $is_admin} --content-type application/json --headers { Authorization: $"token ($token)" } --full --allow-errors
  if $r.status != 200 {
    print $"  ($username): admin=($is_admin) failed ($r.status) - ($r.body)"
  } else {
    print $"  ($username): admin=($is_admin)"
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

  # Snapshot admins before creating anyone (creation never grants admin, so the snapshot stays valid for the
  # delta below). Mint a token only if there's key registration or an admin promote/demote to do.
  let admins_now = current_admins
  let needs_keys = $users | any {|u| (($u.sshKeys? | default []) | is-not-empty) }
  let needs_admin = $users | any {|u| ($u.isAdmin? | default false) != ($u.username in $admins_now) }
  let tok = if ($needs_keys or $needs_admin) { admin_token } else { null }
  let token = if $tok != null { $tok.token } else { "" }

  for u in $users { ensure_user $u $token }

  for u in $users {
    let want = $u.isAdmin? | default false
    if $want != ($u.username in $admins_now) { set_admin $u.username $want $token }
  }

  if $tok != null {
    revoke_token $tok
    print "Revoked ephemeral admin token"
  }
  print "Gitea configuration complete"
}
