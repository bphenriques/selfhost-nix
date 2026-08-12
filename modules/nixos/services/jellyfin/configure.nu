# Reconciles Jellyfin: startup wizard, server settings, libraries and accounts.
# Payload fields are declared in api-contract.json, asserted against /api-docs/openapi.json by the VM test.
# Create-and-update only: dropping a library or user from the config never removes it in Jellyfin.
let base_url = $env.JELLYFIN_URL
let admin_username = $env.JELLYFIN_ADMIN_USERNAME
let admin_password = open $env.JELLYFIN_ADMIN_PASSWORD_FILE | str trim
let config = open $env.JELLYFIN_CONFIG_FILE

# Unauthenticated, and the reason neither readiness nor wizard state is read off an auth failure.
def public_info [] {
  http get $"($base_url)/System/Info/Public" --max-time 2sec
}

def wait_ready [] {
  for attempt in 1..60 {
    print $"Waiting for Jellyfin... ($attempt)"
    let r = try { public_info } catch { null }
    # Jellyfin answers this endpoint mid-startup with ASP.NET's default camelCase, before its own
    # PascalCase serializer is wired up. Responding is therefore not enough: wait for the casing the
    # rest of the script reads, or every field lookup below fails on a fast-answering server.
    if $r != null and "StartupWizardCompleted" in ($r | columns) { return $r }
    sleep 2sec
  }
  error make {msg: "Jellyfin failed to start after 60 attempts"}
}

# POST /Startup/User returns 500 unless the GET has created the default user first.
def complete_startup_wizard [] {
  print "Running startup wizard..."
  let startup = $config.startup
  let r1 = http post $"($base_url)/Startup/Configuration" {
    UICulture: $startup.uiCulture
    MetadataCountryCode: $startup.metadataCountryCode
    PreferredMetadataLanguage: $startup.preferredMetadataLanguage
  } --content-type application/json --full --allow-errors
  if $r1.status != 204 {
    error make {msg: $"Failed to configure startup: ($r1.status) - ($r1.body)"}
  }

  let r2 = http get $"($base_url)/Startup/User" --full --allow-errors
  if $r2.status != 200 {
    error make {msg: $"Failed to read startup user: ($r2.status) - ($r2.body)"}
  }
  let r3 = http post $"($base_url)/Startup/User" {Name: $admin_username, Password: $admin_password} --content-type application/json --full --allow-errors
  if $r3.status != 204 {
    error make {msg: $"Failed to create admin: ($r3.status) - ($r3.body)"}
  }

  let r4 = http post $"($base_url)/Startup/RemoteAccess" {EnableRemoteAccess: true, EnableAutomaticPortMapping: false} --content-type application/json --full --allow-errors
  if $r4.status != 204 {
    error make {msg: $"Failed to configure remote access: ($r4.status) - ($r4.body)"}
  }
  let r5 = http post $"($base_url)/Startup/Complete" {} --content-type application/json --full --allow-errors
  if $r5.status != 204 {
    error make {msg: $"Failed to complete wizard: ($r5.status) - ($r5.body)"}
  }
  print "  Startup wizard completed"
}

def authenticate [] {
  let auth_headers = [Authorization, 'MediaBrowser Client="selfhost", Device="selfhost", DeviceId="selfhost", Version="1"']
  for attempt in 1..30 {
    let r = try {
      http post $"($base_url)/Users/AuthenticateByName" {Username: $admin_username, Pw: $admin_password} --content-type application/json --headers $auth_headers --max-time 5sec --full --allow-errors
    } catch { null }
    if $r != null {
      if $r.status == 200 {
        return [Authorization, $"MediaBrowser Token=\"($r.body.AccessToken)\""]
      }
      # 503 is the server still loading its libraries; anything else is fatal.
      if $r.status != 503 {
        error make {msg: $"Failed to authenticate: ($r.status) - ($r.body | to json)"}
      }
    }
    sleep 2sec
  }
  error make {msg: "Failed to authenticate after 30 attempts"}
}

def get_config [headers: list<any>, path: string] {
  let r = http get $"($base_url)($path)" --headers $headers --full --allow-errors
  if $r.status != 200 {
    error make {msg: $"Failed to read ($path): ($r.status)"}
  }
  $r.body
}

def post_config [headers: list<any>, path: string, body] {
  let r = http post $"($base_url)($path)" $body --content-type application/json --headers $headers --full --allow-errors
  if $r.status != 204 {
    error make {msg: $"Failed to write ($path): ($r.status) - ($r.body)"}
  }
}

# ServerName and TrickplayOptions share one object, so they take a single read-modify-write.
def ensure_server_config [headers: list<any>] {
  let current = get_config $headers "/System/Configuration"
  let desired = $current
  | upsert ServerName $config.serverName
  | upsert TrickplayOptions ($current.TrickplayOptions | merge $config.trickplay)
  if $current == $desired {
    print "Server configuration up to date"
    return
  }
  post_config $headers "/System/Configuration" $desired
  print "Server configuration updated"
}

# Merged onto what the server holds: the DTO also carries LoginDisclaimer, which an SSO plugin may own.
def ensure_branding [headers: list<any>] {
  if ($config.branding | is-empty) { return }
  let current = get_config $headers "/Branding/Configuration"
  let desired = $current | merge $config.branding
  if $current == $desired {
    print "Branding up to date"
    return
  }
  post_config $headers "/System/Configuration/Branding" $desired
  print "Branding updated"
}

def ensure_encoding [headers: list<any>] {
  if ($config.encoding | is-empty) { return }
  let current = get_config $headers "/System/Configuration/encoding"
  let desired = $current | merge $config.encoding
  if $current == $desired {
    print "Encoding up to date"
    return
  }
  post_config $headers "/System/Configuration/encoding" $desired
  print "Encoding updated"
}

def ensure_libraries [headers: list<any>] {
  let existing = get_config $headers "/Library/VirtualFolders"
  for lib in $config.libraries {
    let desired_options = $lib.options | merge {PathInfos: ($lib.locations | each {|p| {Path: $p}})}
    let found = $existing | where Name == $lib.name | get 0?
    if $found == null {
      let paths = $lib.locations | each {|p| $"&paths=($p | url encode)" } | str join ""
      let url = $"($base_url)/Library/VirtualFolders?name=($lib.name | url encode)&collectionType=($lib.collectionType)($paths)&refreshLibrary=false"
      let r = http post $url {LibraryOptions: $lib.options} --content-type application/json --headers $headers --full --allow-errors
      if $r.status != 204 {
        error make {msg: $"Failed to create library ($lib.name): ($r.status) - ($r.body)"}
      }
      print $"  ($lib.name): created"
      continue
    }

    let lo = $found.LibraryOptions
    let desired = $lo | merge $desired_options
    if $lo == $desired {
      print $"  ($lib.name): up to date"
    } else {
      post_config $headers "/Library/VirtualFolders/LibraryOptions" {Id: $found.ItemId, LibraryOptions: $desired}
      print $"  ($lib.name): updated"
    }
  }
}

# passwordFile is a bootstrap credential: applied at creation and never reconciled, so a later in-app
# change sticks. Policy is reconciled on every run.
def ensure_users [headers: list<any>] {
  mut existing = get_config $headers "/Users"
  for user in $config.users {
    if ($existing | where Name == $user.username | is-empty) {
      let password = if $user.passwordFile == null {
        random chars --length 32
      } else {
        open $user.passwordFile | str trim
      }
      let r = http post $"($base_url)/Users/New" {Name: $user.username, Password: $password} --content-type application/json --headers $headers --full --allow-errors
      if $r.status != 200 {
        error make {msg: $"Failed to create user ($user.username): ($r.status) - ($r.body)"}
      }
      print $"  ($user.username): created"
      $existing = (get_config $headers "/Users")
    } else {
      print $"  ($user.username): exists"
    }

    if ($user.policy | is-empty) { continue }
    let found = $existing | where Name == $user.username | get 0?
    if $found == null {
      error make {msg: $"User ($user.username) missing after creation"}
    }
    let desired = $found.Policy | merge $user.policy
    if $found.Policy == $desired {
      print $"  ($user.username): policy up to date"
    } else {
      post_config $headers $"/Users/($found.Id)/Policy" $desired
      print $"  ($user.username): policy updated"
    }
  }
}

def main [] {
  let info = wait_ready
  print "Jellyfin is ready"
  if $info.StartupWizardCompleted {
    print "Startup wizard already completed"
  } else {
    complete_startup_wizard
    sleep 2sec
  }

  let headers = authenticate
  ensure_server_config $headers
  ensure_branding $headers
  ensure_encoding $headers
  print "Reconciling libraries..."
  ensure_libraries $headers
  print "Reconciling users..."
  ensure_users $headers
  print "Jellyfin configuration complete"
}
