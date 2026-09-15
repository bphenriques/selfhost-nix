#!/usr/bin/env nu
# Provisions the single-node cluster layout, then the buckets and keys declared by the consumer.
#
# Garage refuses to store anything until a layout is applied, and the layout is the one piece of
# state that cannot be expressed in the config file. Keys are imported rather than generated so the
# credentials stay in runtime secrets like every other secret.

let provision = open $env.GARAGE_PROVISION_FILE

def wait_ready [] {
  for attempt in 1..30 {
    print $"Waiting for Garage... ($attempt)"
    let r = do -i { ^garage status } | complete
    if $r.exit_code == 0 { return $r.stdout }
    sleep 2sec
  }
  error make {msg: "Garage did not become ready after 30 attempts"}
}

def node_id [status: string] {
  let id = $status | lines | parse -r '^(?<id>[0-9a-f]{16})' | get -o id.0
  if ($id | is-empty) { error make {msg: $"Could not read this node's ID from status:\n($status)"} }
  $id
}

def ensure_layout [node: string] {
  let layout = (^garage layout show)
  if ($layout | str contains $node) and not ($layout | str contains "STAGED") {
    print "Layout already applied"
    return
  }
  print $"Assigning layout to ($node)..."
  ^garage layout assign -z default -c $provision.capacity $node
  # `layout apply` demands the target version as a safety interlock; garage prints the one it expects.
  let staged = (^garage layout show)
  let version = $staged | parse -r 'apply --version (?<v>\d+)' | get -o v.0
  if ($version | is-empty) { error make {msg: $"Could not read the staged layout version:\n($staged)"} }
  ^garage layout apply --version ($version | into int)
}

def ensure_bucket [name: string] {
  let buckets = (^garage bucket list)
  if not ($buckets | str contains $name) {
    print $"Creating bucket ($name)..."
    ^garage bucket create $name
  }
}

def ensure_key [name: string, env_file: string] {
  let creds = open --raw $env_file | lines | parse "{k}={v}" | transpose -rd
  let key_id = $creds.AWS_ACCESS_KEY_ID
  if not ((^garage key list) | str contains $key_id) {
    print $"Importing key ($name)..."
    ^garage key import $key_id $creds.AWS_SECRET_ACCESS_KEY --yes -n $name
  }
  ^garage bucket allow --read --write --owner $name --key $key_id
  print $"  ($name): bucket and key ready"
}

def main [] {
  let status = wait_ready
  ensure_layout (node_id $status)

  for b in $provision.buckets {
    ensure_bucket $b
    ensure_key $b ($provision.keyEnvFiles | get $b)
  }

  print "Garage provisioning complete"
}
