#!/usr/bin/env nu
# WireGuard client key custody (IPv4 only). The server generates each keypair and stores the private
# key (0600, root); the public key is declared in the registry, so peers are declarative — no runtime
# `wg set`. `show` renders the config QR to scan onto the device in person. No email delivery.
def require_env [name: string] {
  let val = $env | get -o $name
  if $val == null or ($val | is-empty) {
    error make {msg: $"($name) required"}
  } else {
    $val
  }
}
let data_dir = require_env "WG_DATA_DIR"
let interface = require_env "WG_INTERFACE"
let endpoint = require_env "WG_SERVER_ENDPOINT"
let client_subnet = require_env "WG_CLIENT_SUBNET"
let client_dns = require_env "WG_CLIENT_DNS"
let selfhost_name = require_env "WG_HOMELAB_NAME"
let allowed_ips_full = $env.WG_SERVER_ALLOWED_IPS? | default $client_subnet
let clients_dir = $"($data_dir)/clients"
let server_pubkey_file = $"($data_dir)/server/public.key"
if not ($server_pubkey_file | path exists) { error make {msg: "Server key not found. Start wireguard service first."} }

def get_server_pubkey [] {
  open --raw $server_pubkey_file | str trim
}

def validate_iface_name [device: string] {
  let iface_name = $"($selfhost_name)-($device)"
  if ($iface_name | str length) > 15 {
    error make {msg: $"Interface name '($iface_name)' exceeds 15 chars"}
  }
  if ($iface_name | str replace --all --regex '[a-z0-9-]' '' | is-not-empty) {
    error make {msg: $"Interface name '($iface_name)' contains invalid characters [allowed: a-z, 0-9, -]"}
  }
}

# The client name is a directory key interpolated into filesystem paths (incl. rm), so reject anything that
# could escape the clients dir. Admin-run, so this is a foot-gun guard, not an exploit boundary.
def validate_name [name: string] {
  if ($name | is-empty) or ($name | str replace --all --regex '[a-z0-9-]' '' | is-not-empty) {
    error make {msg: $"Client name '($name)' contains invalid characters [allowed: a-z, 0-9, -]"}
  }
}

def conf_file [name: string, device: string] {
  validate_iface_name $device
  $"($clients_dir)/($name)/($selfhost_name)-($device).conf"
}

def get_client [name: string] {
  let dir = $"($clients_dir)/($name)"
  if not ($dir | path exists) {
    error make {msg: $"Client '($name)' not found"}
  }
  open $"($dir)/meta.json"
}

def show_qr [name: string] {
  let meta = get_client $name
  open --raw (conf_file $name $meta.device) | qrencode -t ANSIUTF8
}

def list_clients [] {
  if not ($clients_dir | path exists) { return [] }
  ls $clients_dir | where type == dir | each {|d| $"($d.name)/meta.json" } | where { $in | path exists } | each { open $in }
}

def next_ip [] {

  # Assumes IPv4 /24 subnet
  let parts = $client_subnet | split row "/"
  let base_ip = $parts | get 0
  let cidr = $parts | get 1 | into int
  if $cidr != 24 {
    error make {msg: $"Only /24 subnets supported (got /($cidr))"}
  }
  let prefix = (
    $base_ip
    | split row "."
    | slice 0..2
    | str join "."
  )
  let used = (
    list_clients | get -o ip | default [] | each {|ip| $ip | split row "." | get 3 | into int }
  )
  let next = 2..254 | where {|n| not ($n in $used) } | get 0?
  if $next == null {
    error make {msg: "No free IPs"}
  } else {
    $"($prefix).($next)"
  }
}

def render_conf [priv_key: string, ip: string] {
  $"[Interface]
PrivateKey = ($priv_key)
Address = ($ip)/32
DNS = ($client_dns)

[Peer]
PublicKey = (get_server_pubkey)
Endpoint = ($endpoint)
AllowedIPs = ($allowed_ips_full)
PersistentKeepalive = 25
"
}

# Not thread-safe: concurrent calls may assign the same IP
def create_client [name: string, --ip: string, --device: string] {
  let dir = $"($clients_dir)/($name)"
  let client_ip = if $ip == null { next_ip } else { $ip }
  let dev = if $device == null { $name } else { $device }
  validate_iface_name $dev
  mkdir $dir
  chmod 0700 $dir
  let priv_key = wg genkey | str trim
  let pub_key = $priv_key | wg pubkey | str trim
  $priv_key | save -f $"($dir)/private.key"
  chmod 0600 $"($dir)/private.key"
  {
    name: $name
    device: $dev
    ip: $client_ip
    pub_key: $pub_key
  } | save -f $"($dir)/meta.json"
  let conf = conf_file $name $dev
  render_conf $priv_key $client_ip | save -f $conf
  chmod 0600 $conf
  print $"Client '($name)' provisioned (($client_ip))"
  print $"  publicKey = \"($pub_key)\""
  print "Add this device to the WireGuard registry (name/ip/fullAccess/publicKey) and rebuild to enable the peer."
}

def "main list" [] {
  let clients = list_clients
  if ($clients | is-empty) {
    print "No clients"
  } else {
    $clients | select name ip pub_key | print
  }
}

def "main status" [] {
  let clients = list_clients
  if ($clients | is-empty) {
    print "No clients"
    return
  }
  # Build pub_key -> handshake_epoch dictionary for O(1) lookups
  let peer_map = (
    try { wg show $interface dump } catch { "" } | lines | skip 1 | where {|l| ($l | str trim) != "" } | reduce -f {} {|line, acc|
        let f = $line | split row "\t"
        let pk = $f | get -o 0 | default ""
        if $pk == "" { $acc } else {
          $acc | insert $pk ($f | get -o 4 | default "0" | into int)
        }
      }
  )
  let now = (date now | into int) // 1_000_000_000
  # PersistentKeepalive = 25s → WireGuard re-handshakes ~every 2min.
  # 3min window gives 1min slack before marking inactive.
  let active_threshold = 180
  $clients | each {|c|
    let hs = $peer_map | get -o $c.pub_key | default 0
    let ago = if $hs > 0 { [($now - $hs) 0] | math max } else { null }

    let handshake = if $ago == null { "never"
      } else if $ago < 60 { $"($ago)s ago"
      } else if $ago < 3600 { $"($ago // 60)m ago"
      } else if $ago < 86400 { $"($ago // 3600)h ago"
      } else { $"($ago // 86400)d ago" }

    let status = if $ago != null and $ago < $active_threshold { "●" } else { "○" }

    { status: $status, name: $c.name, ip: $c.ip, handshake: $handshake }
  }
}

def "main show" [name: string] {
  validate_name $name
  show_qr $name
}

def "main add" [name: string, --device: string, --ip: string] {
  validate_name $name
  let dir = $"($clients_dir)/($name)"
  if ($dir | path exists) {
    print $"Client '($name)' exists"
  } else {
    create_client $name --device $device --ip $ip
  }
  show_qr $name
}

def "main remove" [...names: string] {
  for name in $names {
    validate_name $name
    let dir = $"($clients_dir)/($name)"
    if not ($dir | path exists) {
      print $"Client '($name)' not found"
      continue
    }
    rm -r $dir
    print $"Client '($name)' key removed. Delete it from the registry and rebuild to drop the peer."
  }
}

def main [] {
  print "wg-manage - WireGuard client key custody (peers are declared in the registry)

  list                          List clients
  status                        Show connection status of all clients
  add <name> [--device] [--ip]  Generate a keypair; prints the publicKey to add to the registry
  show <name>                   Show the config QR for a client (scan onto the device)
  remove <name>...              Delete a client's key (then remove it from the registry + rebuild)"
}
