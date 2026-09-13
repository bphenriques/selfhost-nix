# Reconciles FileBrowser Quantum users against the running server.
# Payload fields are declared in api-contract.json, asserted against /swagger/doc.json by the VM test.
# The CLI only creates password accounts, so every other login method is declared here instead.
let base_url = $env.FILEBROWSER_URL
let config = open $env.FILEBROWSER_CONFIG_FILE
let admin = $env.FILEBROWSER_ADMIN_USERNAME
let password = open --raw $"($env.CREDENTIALS_DIRECTORY)/admin-password" | str trim

def wait_ready [] {
  for attempt in 1..60 {
    print $"Waiting for FileBrowser... ($attempt)"
    try {
      http get $"($base_url)/health" --max-time 2sec | ignore
      return
    } catch { sleep 2sec }
  }
  error make {msg: "FileBrowser failed to start after 60 attempts"}
}

# Secrets stay out of the message: a failure here is almost always the password file.
def login [] {
  let r = (http post $"($base_url)/api/auth/login?username=($admin)" ""
    --headers {X-Password: $password} --full --allow-errors)
  if $r.status != 200 {
    error make {msg: $"Failed to authenticate as ($admin): ($r.status)"}
  }
  $r.body | into string | str trim
}

def get_users [headers: record] {
  let r = http get $"($base_url)/api/users" --headers $headers --full --allow-errors
  if $r.status != 200 {
    error make {msg: $"Failed to list users: ($r.status) - ($r.body)"}
  }
  $r.body
}

def payload [user: record] {
  {
    username: $user.username
    loginMethod: $config.loginMethod
    scopes: [
      {name: $config.sourceName, scope: $user.scope}
    ]
    permissions: ($user.permissions | merge {admin: $user.admin})
  }
}

def create_user [headers: record, user: record] {
  let r = (http post $"($base_url)/api/users" {which: [], data: (payload $user)}
    --headers $headers --content-type application/json --full --allow-errors)
  if $r.status not-in [200, 201] {
    error make {msg: $"Failed to create ($user.username): ($r.status) - ($r.body)"}
  }
  print $"  ($user.username): created"
}

def update_user [headers: record, user: record, id: int] {
  let body = {
    which: ["scopes" "permissions"]
    data: ((payload $user) | merge {id: $id})
  }
  let r = (http put $"($base_url)/api/users?id=($id)" $body
    --headers $headers --content-type application/json --full --allow-errors)
  if $r.status not-in [200, 201, 204] {
    error make {msg: $"Failed to update ($user.username): ($r.status) - ($r.body)"}
  }
  print $"  ($user.username): updated"
}

def delete_user [headers: record, username: string, id: int] {
  let r = http delete $"($base_url)/api/users?id=($id)" --headers $headers --full --allow-errors
  if $r.status not-in [200, 204] {
    error make {msg: $"Failed to delete ($username): ($r.status) - ($r.body)"}
  }
  print $"  ($username): deleted"
}

def main [] {
  wait_ready
  # A password actor must re-confirm on every user mutation, so X-Password rides along with the token.
  let headers = {
    Authorization: $"Bearer (login)"
    X-Password: $password
  }

  let declared = $config.users | reduce --fold {} {|u, acc| $acc | merge {($u.username): $u}}
  # Only accounts of the declared login method are ours; the admin logs in with a password.
  let existing = (get_users $headers
    | where loginMethod == $config.loginMethod
    | reduce --fold {} {|u, acc| $acc | merge {($u.username): $u.id}})

  print "Reconciling users..."
  for user in $config.users {
    if $user.username in $existing {
      update_user $headers $user ($existing | get $user.username)
    } else {
      create_user $headers $user
    }
  }
  # Dropping a user from the config revokes their access, so the reconcile deletes as well as creates.
  for name in ($existing | columns) {
    if not ($name in $declared) {
      delete_user $headers $name ($existing | get $name)
    }
  }
  print "FileBrowser configuration complete"
}
