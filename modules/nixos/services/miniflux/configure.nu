#!/usr/bin/env nu
# Reconciles each Miniflux user's settings via the partial PUT (is_admin from the fleet isAdmin, the rest
# freeform); only touches users that already exist (auto-provisioned on OIDC login).
let base_url = $env.MINIFLUX_URL
let admin_username = $env.MINIFLUX_ADMIN_USERNAME
let admin_password = open $env.MINIFLUX_ADMIN_PASSWORD_FILE | str trim
let users = open $env.MINIFLUX_USERS_FILE
def wait_ready [] {
  for attempt in 1..30 {
    print $"Waiting for Miniflux... ($attempt)"
    try {
      http get $"($base_url)/healthcheck" --max-time 2sec | ignore
      return
    } catch { sleep 2sec }
  }
  error make {msg: "Miniflux failed to start after 30 attempts"}
}
def get_users [] {
  let r = http get $"($base_url)/v1/users" --user $admin_username --password $admin_password --full --allow-errors
  if $r.status != 200 { error make {msg: $"Failed to list users: ($r.status) - ($r.body)"} }
  $r.body
}
def update_user [user_id: int, settings: record] {
  let r = http put $"($base_url)/v1/users/($user_id)" $settings --user $admin_username --password $admin_password --content-type application/json --full --allow-errors
  if $r.status != 201 { error make {msg: $"Failed to update user ($user_id): ($r.status) - ($r.body)"} }
}
def main [] {
  wait_ready
  print "Miniflux is ready"
  if ($users | default [] | is-empty) {
    print "No users to reconcile"
    return
  }
  let miniflux_users = get_users
  for u in $users {
    let mu = $miniflux_users | where username == $u.username | get 0?
    if $mu == null {
      print $"  ($u.username): not provisioned yet (logs in via OIDC first), skipping"
    } else {
      # PUT only when a desired field drifts from the current record (the endpoint is a partial update).
      let drift = $u.settings | items {|k, v| ($mu | get -o $k) != $v } | any {|d| $d }
      if $drift {
        update_user $mu.id $u.settings
        print $"  ($u.username): settings reconciled"
      } else {
        print $"  ($u.username): settings up to date"
      }
    }
  }
  print "Miniflux settings reconcile complete"
}
