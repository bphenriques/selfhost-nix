#!/usr/bin/env nu
# WireGuard client provisioning (IPv4 only). Peers are declarative: only the public key is declared, so
# they apply with no runtime `wg set`. Nothing about a client is stored here, so there is no local state
# to drift from the registry, and no private key at rest beyond the server's own.
#
# Two enrolment paths. `template` emits a keyless config the recipient regenerates, leaving the private
# key only ever on their device. `issue` mints one and renders its QR once, for someone who cannot do
# that; losing the output means issuing again, which is the same answer as a lost phone.
let config_file = ($env.WG_CONFIG_FILE? | default "")
if ($config_file | is-empty) { error make {msg: "WG_CONFIG_FILE required"} }
let cfg = open $config_file
let server_pubkey = (open --raw $cfg.serverPublicKeyFile | str trim)

# Declared peers are the only inventory: allocation, policy and status all read the same list, so they
# cannot disagree with what the server actually routes.
def next_ip [] {
  let prefix = ($cfg.clientSubnet | split row "/" | get 0 | split row "." | slice 0..2 | str join ".")
  let used = ($cfg.peers | get -o ip | default [] | each {|ip| $ip | split row "." | get 3 | into int })
  let free = (2..254 | where {|n| not ($n in $used) } | get -o 0)
  if $free == null { error make {msg: $"No free addresses in ($cfg.clientSubnet)"} }
  $"($prefix).($free)"
}

def resolve_ip [ip: any] { if $ip == null { next_ip } else { $ip } }

# AllowedIPs is the client's routing table, so a restricted device routes the server alone rather than
# the whole LAN, which would capture the local network of anyone whose home uses the same subnet.
#
# Declared peers resolve from the registry; a device not declared yet has no entry, so `--full-access`
# states the intent up front. Without it the rendered config and the registry line you are told to paste
# could disagree, and the recipient would silently route less than you granted.
def allowed_ips_for [ip: string, full: bool] {
  let peer = ($cfg.peers | where ip == $ip | get -o 0)
  if ($full or ($peer != null and $peer.fullAccess)) { $cfg.allowedIPs.full } else { $cfg.allowedIPs.restricted }
}

def render_conf [priv_key: string, ip: string, full: bool] {
  $"[Interface]
PrivateKey = ($priv_key)
Address = ($ip)/32
DNS = ($cfg.dns)

[Peer]
PublicKey = ($server_pubkey)
Endpoint = ($cfg.endpoint)
AllowedIPs = (allowed_ips_for $ip $full)
PersistentKeepalive = 25
"
}

def declare_hint [device: string, ip: string, full: bool, pubkey: string] {
  print -e "Declare it and rebuild before telling them to connect:"
  print -e $"  \{ name = \"($device)\"; ip = \"($ip)\"; fullAccess = ($full); publicKey = \"($pubkey)\"; \}"
}

# The embedded key is a throwaway, never declared, so the tunnel stays dead until the recipient
# regenerates it: a skipped step fails closed. Guidance goes to stderr so `invite > device.conf` yields
# a file the app imports as-is.
def "main invite" [--ip: string, --device: string = "<device>", --full-access] {
  let addr = (resolve_ip $ip)
  print -e "Send the config below. In the WireGuard app: import it, Edit, regenerate the Private Key,"
  print -e "then send back the Public Key."
  declare_hint $device $addr $full_access "<theirs>"
  render_conf (wg genkey | str trim) $addr $full_access
}

def "main issue" [--ip: string, --device: string = "<device>", --full-access] {
  let addr = (resolve_ip $ip)
  let priv = (wg genkey | str trim)
  declare_hint $device $addr $full_access ($priv | wg pubkey | str trim)
  print -e ""
  render_conf $priv $addr $full_access | qrencode -t ANSIUTF8
}

def "main status" [] {
  if ($cfg.peers | is-empty) { print "No declared peers"; return }
  # Reading the interface needs root. Say so rather than reporting every peer as never connected,
  # which is a wrong answer that sends you debugging a problem that is not there.
  let raw = (try { wg show $cfg.interface dump err> /dev/null } catch { null })
  if $raw == null { print -e $"Cannot read ($cfg.interface): rerun with sudo for handshakes." }
  let dump = (
    ($raw | default "") | lines | skip 1 | where {|l| ($l | str trim) != "" }
    | reduce -f {} {|line, acc| let f = ($line | split row "\t"); $acc | insert ($f | get 0) ($f | get -o 4 | default "0" | into int) }
  )
  let now = ((date now | into int) // 1_000_000_000)
  $cfg.peers | each {|p|
    let hs = ($dump | get -o $p.publicKey | default 0)
    let ago = (if $hs > 0 { [($now - $hs) 0] | math max } else { null })
    {
      peer: $p.name
      ip: $p.ip
      access: (if $p.fullAccess { "lan" } else { "server" })
      handshake: (if $raw == null { "unknown"
        } else if $ago == null { "never"
        } else if $ago < 60 { $"($ago)s ago"
        } else if $ago < 3600 { $"($ago // 60)m ago"
        } else if $ago < 86400 { $"($ago // 3600)h ago"
        } else { $"($ago // 86400)d ago" })
    }
  }
}

def main [] {
  print "wg-manage - WireGuard client provisioning (peers are declared in the registry)

  status                Declared peers and their last handshake
  invite [--ip] [--device] [--full-access]   Keyless config to send; they regenerate the key and return its public half
  issue  [--ip] [--device] [--full-access]   Mint a keypair and render its QR once, for someone who cannot

  Both print the registry line to declare, matching the config they rendered.
  --ip defaults to the next free address; --full-access reaches the LAN, otherwise the server only."
}
