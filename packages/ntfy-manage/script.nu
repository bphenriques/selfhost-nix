#!/usr/bin/env nu
let config = open $env.NTFY_PROVISION_FILE

# Wait for the server's auth DB to exist (it's created on startup); the ntfy CLI fails otherwise.
def wait_ready [] {
  for _ in 1..60 {
    try {
      http get $"($env.NTFY_BASE_URL)/v1/health" --max-time 2sec | ignore
      return
    } catch {
      sleep 1sec
    }
  }
  error make {msg: "ntfy server did not become ready in time"}
}

def setup_admin [] {
  print "Setting up admin user..."
  let password = open $env.NTFY_ADMIN_PASSWORD_FILE | str trim
  with-env { NTFY_PASSWORD: $password } {
    ^ntfy user add --role=admin --ignore-exists admin
    ^ntfy user change-pass admin
  }
}

def setup_public_topics [] {
  let topics = $config | get -o publicTopics | default []
  if ($topics | is-empty) { return }
  print "Setting ACLs for public topics..."
  for topic in $topics {
    ^ntfy access everyone $topic ro
    print $"  ($topic) → everyone ro"
  }
}

def setup_publishers [] {
  let publishers = $config | get -o publishers | default {}
  if ($publishers | is-empty) { return }
  print "Provisioning publishers..."
  for entry in ($publishers | transpose name pub) {
    let name = $entry.name
    let pub = $entry.pub
    let random_pass = (random chars --length 32)
    with-env { NTFY_PASSWORD: $random_pass } {
      ^ntfy user add --ignore-exists $name
    }
    ^ntfy access $name $pub.topic wo
    if ($pub.tokenFile | path exists) {
      print $"  ($name) → ($pub.topic) \(token exists\)"
    } else {
      let token = (
        ^ntfy token add --label $name $name
        | str trim
        | split row " "
        | get 1
      )
      $token | save --raw $pub.tokenFile
      # Own the token by the publisher's system user when it exists (so that user can read it).
      # Task publishers and DynamicUser services have no such user, so fall back to root — they read
      # the token as root or via systemd LoadCredential. (Chowning to a missing user aborts here.)
      let owner = if (do { ^id -u $pub.owner } | complete).exit_code == 0 { $pub.owner } else { "root" }
      ^chown $"($owner):root" $pub.tokenFile
      ^chmod "400" $pub.tokenFile
      print $"  ($name) → ($pub.topic) \(token created\)"
    }
  }
}

# Cleanup is intentionally one-way for now.
# If a publisher is removed from Nix config, this script does not delete the
# corresponding ntfy user/token automatically to avoid accidental lockouts.
# TODO: add opt-in stale user cleanup mode once we have a safe migration path.
def main [] {
  wait_ready
  setup_admin
  setup_public_topics
  setup_publishers
  print "ntfy setup complete"
}
