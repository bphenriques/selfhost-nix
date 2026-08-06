# Reconciles Immich: admin bootstrap, user accounts, and optional external libraries.
# Every endpoint and payload field used here is declared in api-contract.json, which the VM test
# asserts against the server's own /api/spec.json.
#
# Create-and-update only: nothing is ever deleted. Dropping a user or a library from the config leaves
# the Immich side untouched, because removing either would take photos with it.
let base_url = $env.IMMICH_URL
let config = open $env.IMMICH_CONFIG_FILE

def wait_ready [] {
  for attempt in 1..60 {
    print $"Waiting for Immich... ($attempt)"
    try {
      http get $"($base_url)/api/server/ping" --max-time 2sec | ignore
      return
    } catch { sleep 2sec }
  }
  error make {msg: "Immich failed to start after 60 attempts"}
}

# Unauthenticated. isInitialized reports whether the admin account exists, isOnboarded whether the
# admin wizard was dismissed; both gate one-time steps that would otherwise be read off an error status.
def server_config [] {
  let r = http get $"($base_url)/api/server/config" --full --allow-errors
  if $r.status != 200 {
    error make {msg: $"Failed to read server config: ($r.status) - ($r.body)"}
  }
  $r.body
}

def admin_signup [admin: record, password: string] {
  let body = {email: $admin.email, name: $admin.name, password: $password}
  let r = http post $"($base_url)/api/auth/admin-sign-up" $body --content-type application/json --full --allow-errors
  if $r.status != 201 {
    error make {msg: $"Failed to register admin: ($r.status) - ($r.body)"}
  }
  print $"Registered admin ($admin.email)"
}

def login [email: string, password: string] {
  let body = {email: $email, password: $password}
  let r = http post $"($base_url)/api/auth/login" $body --content-type application/json --full --allow-errors
  if $r.status != 201 {
    error make {msg: $"Failed to login: ($r.status) - ($r.body)"}
  }
  $r.body.accessToken
}

def complete_admin_onboarding [headers: record] {
  let r = http post $"($base_url)/api/system-metadata/admin-onboarding" {isOnboarded: true} --headers $headers --content-type application/json --full --allow-errors
  if $r.status not-in [200, 204] {
    error make {msg: $"Failed to complete admin onboarding: ($r.status) - ($r.body)"}
  }
  print "Completed admin onboarding"
}

def get_users [headers: record] {
  let r = http get $"($base_url)/api/admin/users" --headers $headers --full --allow-errors
  if $r.status != 200 {
    error make {msg: $"Failed to list users: ($r.status) - ($r.body)"}
  }
  $r.body
}

def get_libraries [headers: record] {
  let r = http get $"($base_url)/api/libraries" --headers $headers --full --allow-errors
  if $r.status != 200 {
    error make {msg: $"Failed to list libraries: ($r.status) - ($r.body)"}
  }
  $r.body
}

# The password and its change-on-login flag are bootstrap credentials: applied at creation and never
# reconciled, so a later in-app change sticks. Users without a passwordFile get a random password and
# are expected to log in via OIDC. Everything else below is reconciled on every run.
def ensure_user [user: record, existing: list<any>, headers: record] {
  let desired = {isAdmin: $user.isAdmin, quotaSizeInBytes: $user.quotaSizeInBytes, storageLabel: $user.storageLabel}
  let found = $existing | where email == $user.email | get 0?
  if $found != null {
    if ($found | select ...($desired | columns)) == $desired {
      print $"  ($user.email): up to date"
    } else {
      let r = http put $"($base_url)/api/admin/users/($found.id)" $desired --headers $headers --content-type application/json --full --allow-errors
      if $r.status != 200 {
        error make {msg: $"Failed to update ($user.email): ($r.status) - ($r.body)"}
      }
      print $"  ($user.email): updated ($desired)"
    }
    return
  }

  let password = if $user.passwordFile == null {
    random chars --length 32
  } else {
    open $user.passwordFile | str trim
  }
  let body = $desired | merge {
    email: $user.email
    name: $user.name
    password: $password
    shouldChangePassword: $user.shouldChangePassword
  }
  let r = http post $"($base_url)/api/admin/users" $body --content-type application/json --headers $headers --full --allow-errors
  if $r.status != 201 {
    error make {msg: $"Failed to create ($user.email): ($r.status) - ($r.body)"}
  }
  print $"  ($user.email): created ($desired)"
}

def ensure_library [
  lib: record
  owner_id: string
  existing: list<any>
  headers: record
] {
  let found = $existing | where name == $lib.name and ownerId == $owner_id | get 0?
  if $found != null {
    let same = ($found.importPaths | sort) == ($lib.importPaths | sort) and ($found.exclusionPatterns | sort) == ($lib.exclusionPatterns | sort)
    if $same {
      print $"  ($lib.name): up to date"
    } else {
      let body = {name: $lib.name, importPaths: $lib.importPaths, exclusionPatterns: $lib.exclusionPatterns}
      let r = http put $"($base_url)/api/libraries/($found.id)" $body --headers $headers --content-type application/json --full --allow-errors
      if $r.status != 200 {
        error make {msg: $"Failed to update library ($lib.name): ($r.status) - ($r.body)"}
      }
      print $"  ($lib.name): paths updated"
    }
    return
  }

  let body = {
    name: $lib.name
    ownerId: $owner_id
    importPaths: $lib.importPaths
    exclusionPatterns: $lib.exclusionPatterns
  }
  let r = http post $"($base_url)/api/libraries" $body --headers $headers --content-type application/json --full --allow-errors
  if $r.status != 201 {
    error make {msg: $"Failed to create library ($lib.name): ($r.status) - ($r.body)"}
  }
  print $"  ($lib.name): created"

  let scan = http post $"($base_url)/api/libraries/($r.body.id)/scan" {} --headers $headers --content-type application/json --full --allow-errors
  if $scan.status not-in [200, 204] {
    error make {msg: $"Failed to trigger scan for ($lib.name): ($scan.status) - ($scan.body)"}
  }
  print $"  ($lib.name): scan triggered"
}

def main [] {
  wait_ready
  print "Immich is ready"

  let admin = $config.admin
  let password = open $admin.passwordFile | str trim
  let state = server_config
  if not $state.isInitialized {
    admin_signup $admin $password
  } else {
    print $"Admin already registered ($admin.email)"
  }

  let token = login $admin.email $password
  let headers = {"Authorization": $"Bearer ($token)"}
  if not $state.isOnboarded {
    complete_admin_onboarding $headers
  } else {
    print "Admin onboarding already completed"
  }

  print "Reconciling users..."
  let existing_users = get_users $headers
  for user in $config.users {
    ensure_user $user $existing_users $headers
  }

  if ($config.libraries | is-empty) {
    print "No external libraries configured"
    return
  }

  # Owners resolve against the server, so a library may belong to any account that exists by now
  # (a reconciled user or the bootstrap admin), not only to the users created in this run.
  let owners = get_users $headers | reduce --fold {} {|u, acc| $acc | upsert $u.email $u.id }
  let existing_libraries = get_libraries $headers
  print "Reconciling external libraries..."
  for lib in $config.libraries {
    let owner_id = $owners | get -o $lib.ownerEmail
    if $owner_id == null {
      error make {msg: $"Library '($lib.name)' owner '($lib.ownerEmail)' has no Immich account"}
    }
    ensure_library $lib $owner_id $existing_libraries $headers
  }
}
