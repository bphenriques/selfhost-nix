#!/usr/bin/env nu
# Idempotent *arr (Radarr/Sonarr, API v3) reconciler: applies the framework-declared config (root folders,
# download clients, delay profile, notify) and nothing else — acquisition (indexers, quality) is not ours.
let arr_name = $env.ARR_NAME
let base_url = $env.ARR_URL
let api_key = open $env.ARR_API_KEY_FILE | str trim
let config = open $env.ARR_CONFIG_FILE
let headers = [X-Api-Key, $api_key]

def wait_ready [] {
  for attempt in 1..30 {
    print $"Waiting for ($arr_name)... ($attempt)"
    let r = try { http get $"($base_url)/api/v3/system/status" --headers $headers --full --allow-errors } catch { null }
    if $r != null and $r.status == 200 { return }
    sleep 2sec
  }
  error make {msg: $"($arr_name) failed to start after 30 attempts"}
}

# Best-effort: an unresolved profile name (recyclarr hasn't created it yet) seeds the folder without one.
def quality_profile_id [name: string] {
  let r = http get $"($base_url)/api/v3/qualityprofile" --headers $headers --full --allow-errors
  if $r.status != 200 { error make {msg: $"Failed to list quality profiles: ($r.status) - ($r.body)"} }
  let p = $r.body | where name == $name | get 0?
  if $p == null {
    print $"  Quality profile '($name)' not found yet — seeding root folder without a default profile"
    null
  } else {
    $p.id
  }
}

def ensure_root_folders [] {
  let folders = $config | get -o rootFolders | default []
  if ($folders | is-empty) { return }
  print "Reconciling root folders..."
  let existing = http get $"($base_url)/api/v3/rootfolder" --headers $headers --full --allow-errors
  if $existing.status != 200 { error make {msg: $"Failed to list root folders: ($existing.status) - ($existing.body)"} }
  # Root folders are immutable in the *arr API (PUT → 405): create-or-leave. A default profile only applies at
  # creation — an unresolved one (recyclarr not run yet) leaves the folder without one, not backfilled.
  for folder in $folders {
    let found = $existing.body | default [] | where path == $folder.path | get 0?
    if $found != null {
      print $"  Root folder exists: ($folder.path)"
      continue
    }
    let profile_id = if ($folder | get -o defaultQualityProfile) != null { quality_profile_id $folder.defaultQualityProfile } else { null }
    let payload = if $profile_id != null { {path: $folder.path, defaultQualityProfileId: $profile_id} } else { {path: $folder.path} }
    let r = http post $"($base_url)/api/v3/rootfolder" $payload --headers $headers --content-type application/json --full --allow-errors
    if $r.status not-in [200, 201] { error make {msg: $"Failed to create root folder ($folder.path): ($r.status) - ($r.body)"} }
    print $"  Created root folder: ($folder.path)"
  }
}

# Generic over the implementation: fetch the client's own schema, fill the caller-supplied fields by name,
# and upsert. Protocol and implementation are the caller's — no torrent/Transmission assumption.
def ensure_download_clients [] {
  let clients = $config | get -o downloadClients | default []
  if ($clients | is-empty) { return }
  print "Reconciling download clients..."
  let existing = http get $"($base_url)/api/v3/downloadclient" --headers $headers --full --allow-errors
  if $existing.status != 200 { error make {msg: $"Failed to list download clients: ($existing.status) - ($existing.body)"} }
  let schemas = http get $"($base_url)/api/v3/downloadclient/schema" --headers $headers --full --allow-errors
  if $schemas.status != 200 { error make {msg: $"Failed to list download-client schemas: ($schemas.status)"} }
  let managed = $clients | get name
  for client in $clients {
    let schema = $schemas.body | where implementation == $client.implementation | get 0?
    if $schema == null { error make {msg: $"Download-client schema not found: ($client.implementation)"} }
    let supplied = $client | get -o fields | default {}
    let fields = $schema.fields | each {|f| if ($f.name in ($supplied | columns)) { $f | upsert value ($supplied | get $f.name) } else { $f } }
    let base = {
      name: $client.name
      enable: true
      protocol: $client.protocol
      priority: 1
      removeCompletedDownloads: true
      removeFailedDownloads: true
      fields: $fields
      implementation: $schema.implementation
      implementationName: $schema.implementationName
      configContract: $schema.configContract
    }
    let found = $existing.body | default [] | where name == $client.name | get 0?
    # The *arr connection-tests a download client on save (forceSave does not skip it), so the client must be
    # reachable here — order this reconcile after its service via the app's `configureAfter`.
    if $found == null {
      let r = http post $"($base_url)/api/v3/downloadclient" $base --headers $headers --content-type application/json --full --allow-errors
      if $r.status not-in [200, 201] { error make {msg: $"Failed to create download client ($client.name): ($r.status) - ($r.body)"} }
      print $"  Created download client: ($client.name)"
    } else {
      let r = http put $"($base_url)/api/v3/downloadclient/($found.id)" ($base | merge { id: $found.id }) --headers $headers --content-type application/json --full --allow-errors
      if $r.status != 202 { error make {msg: $"Failed to update download client ($client.name): ($r.status) - ($r.body)"} }
      print $"  Updated download client: ($client.name)"
    }
  }
  # Disable managed-implementation clients we no longer declare, so a removed client stops being used.
  let impls = $clients | get implementation | uniq
  let stale = $existing.body | default [] | where implementation in $impls | where name not-in $managed | where enable == true
  for client in $stale {
    let r = http put $"($base_url)/api/v3/downloadclient/($client.id)" ($client | merge { enable: false }) --headers $headers --content-type application/json --full --allow-errors
    if $r.status != 202 { error make {msg: $"Failed to disable stale download client ($client.name): ($r.status) - ($r.body)"} }
    print $"  Disabled stale download client: ($client.name)"
  }
}

def ensure_delay_profile [] {
  let profile = $config | get -o delayProfile
  if $profile == null { return }
  print "Reconciling default delay profile..."
  let existing = http get $"($base_url)/api/v3/delayprofile" --headers $headers --full --allow-errors
  if $existing.status != 200 { error make {msg: $"Failed to list delay profiles: ($existing.status) - ($existing.body)"} }
  let defaults = $existing.body | where tags == []
  if ($defaults | length) != 1 {
    print $"  Expected exactly one default delay profile, found ($defaults | length) — skipping"
    return
  }
  let current = $defaults | get 0
  let r = http put $"($base_url)/api/v3/delayprofile/($current.id)" ($current | merge $profile) --headers $headers --content-type application/json --full --allow-errors
  if $r.status not-in [200, 202] { error make {msg: $"Failed to update delay profile: ($r.status) - ($r.body)"} }
  print "  Updated default delay profile"
}

# ntfy connection (framework notify seam). Created once; left alone if already present.
def ensure_notification [] {
  let n = $config | get -o notification
  if $n == null { return }
  print "Reconciling ntfy notification..."
  let token = open $env.NTFY_TOKEN_FILE | str trim
  let existing = http get $"($base_url)/api/v3/notification" --headers $headers --full --allow-errors
  if $existing.status != 200 { error make {msg: $"Failed to list notifications: ($existing.status) - ($existing.body)"} }
  if "ntfy" in ($existing.body | default [] | get -o name | default []) {
    print "  Notification exists: ntfy"
    return
  }
  let schemas = http get $"($base_url)/api/v3/notification/schema" --headers $headers --full --allow-errors
  if $schemas.status != 200 { error make {msg: $"Failed to list notification schemas: ($schemas.status)"} }
  let schema = $schemas.body | where implementation == "Ntfy" | get 0?
  if $schema == null { error make {msg: "Ntfy notification schema not found"} }
  let fields = $schema.fields | each { |f|
    match $f.name {
      "serverUrl" => ($f | upsert value $n.serverUrl)
      "accessToken" => ($f | upsert value $token)
      "topics" => ($f | upsert value $n.topic)
      "tags" => ($f | upsert value ($n | get -o tags | default ""))
      _ => $f
    }
  }
  let payload = {
    name: "ntfy"
    enable: true
    fields: $fields
    implementation: "Ntfy"
    implementationName: "Ntfy"
    configContract: "NtfySettings"
    onDownload: true
    onUpgrade: true
    onGrab: false
    onRename: false
    onHealthIssue: false
    onApplicationUpdate: false
  }
  let r = http post $"($base_url)/api/v3/notification" $payload --headers $headers --content-type application/json --full --allow-errors
  if $r.status not-in [200, 201] { error make {msg: $"Failed to create notification: ($r.status) - ($r.body)"} }
  print "  Created notification: ntfy"
}

def main [] {
  wait_ready
  print $"($arr_name) is ready"
  ensure_root_folders
  ensure_download_clients
  ensure_delay_profile
  ensure_notification
  print $"($arr_name) reconcile complete"
}
