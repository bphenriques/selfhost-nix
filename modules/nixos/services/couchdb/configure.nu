#!/usr/bin/env nu
# Reconciles CouchDB system databases, user accounts and their databases.
let base_url = $env.COUCHDB_URL
let admin_user = $env.COUCHDB_ADMIN_USER
let admin_pass = open --raw $env.COUCHDB_ADMIN_PASS_FILE | str trim

def wait_ready [] {
  for attempt in 1..30 {
    print $"Waiting for CouchDB... ($attempt)"
    try {
      http get $"($base_url)/_up" --max-time 2sec | ignore
      return
    } catch { sleep 2sec }
  }
  error make {msg: "CouchDB failed to start after 30 attempts"}
}

def put_database [name: string] {
  let r = http put $"($base_url)/($name)" {} --content-type application/json --user $admin_user --password $admin_pass --full --allow-errors
  if $r.status not-in [201, 412] { error make {msg: $"Failed to create database ($name): ($r.status) - ($r.body)"} }
}

# `single_node` in the ini makes /_cluster_setup report itself already done, so the setup action that
# would create these never runs and the first user PUT 404s. Create them directly instead.
# `_global_changes` is left out: it costs a write per update and only serves /_db_updates.
def ensure_system_databases [] {
  for db in ["_users" "_replicator"] { put_database $db }
}

def ensure_user [name: string, password_file: string] {
  let url = $"($base_url)/_users/org.couchdb.user:($name)"
  let body = {
    name: $name
    password: (open --raw $password_file | str trim)
    roles: []
    type: "user"
  }

  print $"Updating user ($name)..."
  let r = http put $url $body --content-type application/json --user $admin_user --password $admin_pass --full --allow-errors
  match $r.status {
    201 => { }
    409 => {
      let rev = (http get $url --user $admin_user --password $admin_pass)._rev
      let update = http put $url ($body | insert _rev $rev) --content-type application/json --user $admin_user --password $admin_pass --full --allow-errors
      if $update.status not-in [200, 201] {
        error make {msg: $"Failed to update user ($name): ($update.status) - ($update.body)"}
      }
    }
    _ => { error make {msg: $"Failed to create user ($name): ($r.status) - ($r.body)"} }
  }
}

def ensure_database [name: string, owner: string] {
  put_database $name
  let security = {
    admins: {
      names: [$owner]
      roles: []
    }
    members: {
      names: [$owner]
      roles: []
    }
  }
  let sr = http put $"($base_url)/($name)/_security" $security --content-type application/json --user $admin_user --password $admin_pass --full --allow-errors
  if $sr.status != 200 { error make {msg: $"Failed to secure database ($name): ($sr.status) - ($sr.body)"} }
  print $"  ($name): owned by ($owner)"
}

def main [] {
  wait_ready
  ensure_system_databases

  let provision = open $env.COUCHDB_PROVISION_FILE
  $provision.users | each {|u| ensure_user $u.name $u.passwordFile } | ignore
  $provision.databases | each {|db| ensure_database $db.name $db.owner } | ignore

  print "CouchDB reconciliation complete"
}
