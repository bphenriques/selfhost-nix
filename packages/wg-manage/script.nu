#!/usr/bin/env nu
# WireGuard client provisioning (IPv4 only). Nothing is stored here, so there is no state to drift from
# the registry and no private key at rest beyond the server's own. A device's tier is its address:
# inside `fullAccessSubnet` it reaches the LAN, anywhere else only the server's restricted ports.
let config_file = ($env.WG_CONFIG_FILE? | default "")
if ($config_file | is-empty) { error make {msg: "WG_CONFIG_FILE required"} }
let cfg = open $config_file
let server_pubkey = (open --raw $cfg.serverPublicKeyFile | str trim)

def ip_to_int [ip: string] {
  $ip | split row "." | each {|o| $o | into int } | reduce -f 0 {|o, acc| $acc * 256 + $o }
}

def in_subnet [ip: string, cidr: any] {
  if $cidr == null { return false }
  let parts = ($cidr | split row "/")
  let mask = (4294967296 - (2 ** (32 - ($parts | get 1 | into int))))
  ((ip_to_int $ip) | bits and $mask) == ((ip_to_int ($parts | get 0)) | bits and $mask)
}

def int_to_ip [n: int] { [24 16 8 0] | each {|s| ($n | bits shr $s) | bits and 255 | into string } | str join "." }

# The pool is the tier, and declared peers plus the server are the only addresses already spoken for.
def next_ip [full: bool] {
  if $full and $cfg.fullAccessSubnet == null {
    error make {msg: "No fullAccessSubnet is configured, so there is no full-access pool to allocate from"}
  }
  let parts = ($cfg.clientSubnet | split row "/")
  let base = (ip_to_int ($parts | get 0))
  let hosts = ((2 ** (32 - ($parts | get 1 | into int))) - 2)
  let used = (($cfg.peers | get -o ip | default []) | append ($cfg.address | split row "/" | get 0))
  let free = (
    1..$hosts | each {|i| int_to_ip ($base + $i) }
    | where {|ip| (in_subnet $ip $cfg.fullAccessSubnet) == $full and not ($ip in $used) }
    | get -o 0
  )
  if $free == null {
    error make {msg: $"No free addresses in (if $full { $cfg.fullAccessSubnet } else { $cfg.clientSubnet })"}
  }
  $free
}

def resolve_ip [ip: any, full: bool] {
  if $ip == null { return (next_ip $full) }
  if $full and not (in_subnet $ip $cfg.fullAccessSubnet) {
    error make {msg: $"($ip) sits outside ($cfg.fullAccessSubnet), so it cannot be full-access"}
  }
  $ip
}

# AllowedIPs is the client's routing table, so a restricted device routes the server alone rather than
# the whole LAN, which would capture the local network of anyone whose home uses the same subnet.
def allowed_ips_for [ip: string] {
  if (in_subnet $ip $cfg.fullAccessSubnet) { $cfg.allowedIPs.full } else { $cfg.allowedIPs.restricted }
}

def render_conf [priv_key: string, ip: string] {
  $"[Interface]
PrivateKey = ($priv_key)
Address = ($ip)/32
DNS = ($cfg.dns)

[Peer]
PublicKey = ($server_pubkey)
Endpoint = ($cfg.endpoint)
AllowedIPs = (allowed_ips_for $ip)
PersistentKeepalive = 25
"
}

def declare_hint [device: string, ip: string, pubkey: string] {
  print -e "Declare it before the next deploy, which reaps whatever is not in the registry:"
  print -e $"  \{ name = \"($device)\"; ip = \"($ip)\"; publicKey = \"($pubkey)\"; \}"
}

# The embedded key is a throwaway, never declared, so the tunnel stays dead until the recipient
# regenerates it: a skipped step fails closed. Guidance goes to stderr so `invite > device.conf` yields
# a file the app imports as-is.
def "main invite" [--ip: string, --device: string = "<device>", --full-access] {
  let addr = (resolve_ip $ip $full_access)
  print -e "Send the config below. In the WireGuard app: import it, Edit, regenerate the Private Key,"
  print -e "then send back the Public Key."
  declare_hint $device $addr "<theirs>"
  render_conf (wg genkey | str trim) $addr
}

# Up before rendering, so the QR works the moment it is scanned; declaring it is bookkeeping after that.
def "main issue" [--ip: string, --device: string = "<device>", --full-access] {
  let addr = (resolve_ip $ip $full_access)
  let priv = (wg genkey | str trim)
  let pub = ($priv | wg pubkey | str trim)
  wg set $cfg.interface peer $pub allowed-ips $"($addr)/32"
  print -e $"Peer is live on ($cfg.interface) at ($addr)."
  declare_hint $device $addr $pub
  print -e ""
  render_conf $priv $addr | qrencode -t ANSIUTF8
}


# Cuts the peer now; the registry still has to lose it, or the next deploy puts it straight back.
def "main revoke" [peer: string] {
  let declared = ($cfg.peers | where name == $peer | get -o 0)
  let key = (if $declared == null { $peer } else { $declared.publicKey })
  wg set $cfg.interface peer $key remove
  print -e $"Cut ($key). Delete it from the registry too, or the next deploy restores it."
}

def "main status" [] {
  # Reading the interface needs root. Say so rather than reporting every peer as never connected,
  # which is a wrong answer that sends you debugging a problem that is not there.
  let raw = (try { wg show $cfg.interface dump err> /dev/null } catch { null })
  if $raw == null { print -e $"Cannot read ($cfg.interface): rerun with sudo for handshakes." }
  let dump = (
    ($raw | default "") | lines | skip 1 | where {|l| ($l | str trim) != "" }
    | reduce -f {} {|line, acc| let f = ($line | split row "\t"); $acc | insert ($f | get 0) ($f | get -o 4 | default "0" | into int) }
  )
  # Live but undeclared is invisible in the registry, and vanishes at the next deploy without this.
  let undeclared = ($dump | columns | where {|k| not ($k in ($cfg.peers | get -o publicKey | default [])) })
  if not ($undeclared | is-empty) {
    print -e $"Live but undeclared, reaped on next deploy: ($undeclared | str join ', ')"
  }
  if ($cfg.peers | is-empty) { print "No declared peers"; return }
  let now = ((date now | into int) // 1_000_000_000)
  $cfg.peers | each {|p|
    let hs = ($dump | get -o $p.publicKey | default 0)
    let ago = (if $hs > 0 { [($now - $hs) 0] | math max } else { null })
    {
      peer: $p.name
      ip: $p.ip
      access: (if (in_subnet $p.ip $cfg.fullAccessSubnet) { "lan" } else { "server" })
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

  status                Declared peers, their last handshake, and anything live but undeclared
  invite [--ip] [--device] [--full-access]   Keyless config to send; they regenerate the key and return its public half
  issue  [--ip] [--device] [--full-access]   Mint a keypair, bring the peer up now, and render its QR once
  revoke <peer>         Cut a live peer by declared name or public key (still delete it from the registry)

  `invite` and `issue` print the registry line to declare, matching the config they rendered.
  --ip defaults to the next free address; --full-access allocates from the full-access block, which
  reaches the LAN. Every other address reaches the server's restricted ports only."
}
