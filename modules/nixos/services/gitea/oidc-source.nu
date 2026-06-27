#!/usr/bin/env nu
# Writes Gitea's OIDC auth source into the DB; runs in gitea's preStart, before the server registers providers.
let source_name = $env.OIDC_PROVIDER_NAME
let client_id = open $env.OIDC_CLIENT_ID_FILE | str trim
let client_secret = open $env.OIDC_CLIENT_SECRET_FILE | str trim

def find_auth_source_id [name: string] {
  let r = gitea admin auth list --vertical-bars | complete
  if $r.exit_code != 0 { return null }
  $r.stdout | str trim | lines | skip 1 | each { |line|
    let cols = $line | split row "|" | each {|c| $c | str trim }
    if ($cols | length) >= 4 and $cols.1 == $name { $cols.0 | into int }
  } | flatten | get 0?
}

def main [] {
  let oauth_args = [
    --name
    $source_name
    --provider
    openidConnect
    --key
    $client_id
    --secret
    $client_secret
    --auto-discover-url
    $env.OIDC_DISCOVERY_URL
    --scopes
    "openid,email,profile,groups"
  ]
  let existing_id = find_auth_source_id $source_name
  if $existing_id != null {
    gitea admin auth update-oauth --id ($existing_id | into string) ...$oauth_args
    print $"OIDC source '($source_name)' updated"
    return
  }
  let r = gitea admin auth add-oauth ...$oauth_args | complete
  if $r.exit_code == 0 {
    print $"OIDC source '($source_name)' created"
    return
  }
  if ($r.stderr | str contains "already exists") {
    let id = find_auth_source_id $source_name
    if $id != null {
      gitea admin auth update-oauth --id ($id | into string) ...$oauth_args
      return
    }
  }
  error make {msg: $"Failed to configure OIDC source: ($r.stderr)"}
}
