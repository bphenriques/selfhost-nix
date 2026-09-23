#!/usr/bin/env nu
# WireGuard peers (IPv4 only). This owns the peer file and applies every change to the live interface,
# so nothing needs a deploy. A device's tier is its address: inside `fullAccessSubnet` it reaches the
# LAN, anywhere else only the server's restricted ports.
let config_file = ($env.WG_CONFIG_FILE? | default "")
if ($config_file | is-empty) { error make {msg: "WG_CONFIG_FILE required"} }
let cfg = open $config_file
let server_pubkey = (open --raw $cfg.serverPublicKeyFile | str trim)

def load_peers [] { if ($cfg.peersFile | path exists) { open $cfg.peersFile } else { [] } }

# Rename rather than truncate: a torn write here leaves nobody able to connect after the next boot.
def save_peers [peers: list] {
  let tmp = $"($cfg.peersFile).tmp"
  $peers | to json | save -f $tmp
  mv -f $tmp $cfg.peersFile
}

def ip_to_int [ip: string] {
  $ip | split row "." | each {|o| $o | into int } | reduce -f 0 {|o, acc| $acc * 256 + $o }
}
def int_to_ip [n: int] { [24 16 8 0] | each {|s| ($n | bits shr $s) | bits and 255 | into string } | str join "." }

def in_subnet [ip: string, cidr: any] {
  if $cidr == null { return false }
  let parts = ($cidr | split row "/")
  let mask = (4294967296 - (2 ** (32 - ($parts | get 1 | into int))))
  ((ip_to_int $ip) | bits and $mask) == ((ip_to_int ($parts | get 0)) | bits and $mask)
}

# The pool is the tier, and registered peers plus the server are the only addresses already spoken for.
def next_ip [full: bool] {
  if $full and $cfg.fullAccessSubnet == null {
    error make {msg: "No fullAccessSubnet is configured, so there is no full-access pool to allocate from"}
  }
  let parts = ($cfg.clientSubnet | split row "/")
  let base = (ip_to_int ($parts | get 0))
  let hosts = ((2 ** (32 - ($parts | get 1 | into int))) - 2)
  let used = ((load_peers | get -o ip | default []) | append ($cfg.address | split row "/" | get 0))
  let free = (
    1..$hosts | each {|i| int_to_ip ($base + $i) }
    | where {|ip| (in_subnet $ip $cfg.fullAccessSubnet) == $full and not ($ip in $used) }
    | take 1 | get -o 0
  )
  if $free == null {
    error make {msg: $"No free addresses in (if $full { $cfg.fullAccessSubnet } else { $cfg.clientSubnet })"}
  }
  $free
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

# The name is the handle `revoke` takes, so it has to be unique and unambiguous. wg keys a peer by its
# public key, so a reused one silently becomes a single peer at whichever address was written last.
def register [name: string, ip: string, pubkey: string] {
  if not ($name =~ '^[a-z0-9][a-z0-9-]*$') {
    error make {msg: $"($name) is not a peer name: lowercase alphanumerics and dashes"}
  }
  let peers = (load_peers)
  if ($peers | any {|p| $p.name == $name }) { error make {msg: $"($name) is already registered"} }
  if ($peers | any {|p| $p.ip == $ip }) { error make {msg: $"($ip) is already taken"} }
  if ($peers | any {|p| $p.publicKey == $pubkey }) { error make {msg: $"($pubkey) is already registered"} }
  save_peers ($peers | append {name: $name, ip: $ip, publicKey: $pubkey, added: (date now | format date "%Y-%m-%d")})
  wg set $cfg.interface peer $pubkey allowed-ips $"($ip)/32"
}

# Mints the key, brings the peer up, and renders its QR once. `--conf` prints the config instead, for
# someone you cannot hand a screen to; what you send is then a live credential, which the restricted
# tier is what bounds. Losing the output means adding again, the same answer as a lost phone.
def "main add" [name: string, --full-access, --conf] {
  let addr = (next_ip $full_access)
  let priv = (wg genkey | str trim)
  register $name $addr ($priv | wg pubkey | str trim)
  print -e $"($name) is live at ($addr)."
  if $conf { render_conf $priv $addr } else { render_conf $priv $addr | qrencode -t ANSIUTF8 }
}

# Forget before cutting. The other order means a failed write leaves the peer in the file, and the next
# boot quietly hands the access back. A live peer with no entry has no name to give here; `apply` drops
# those.
def "main remove" [name: string] {
  let peers = (load_peers)
  let match = ($peers | where name == $name | get -o 0)
  if $match == null { error make {msg: $"($name) is not registered"} }
  save_peers ($peers | where name != $name)
  wg set $cfg.interface peer $match.publicKey remove
  print -e $"Removed ($name)."
}

# Full sync in both directions, so it restores the interface when it appears and also picks up a
# hand-edited file. An absent file is not an empty one: it means leave the interface alone.
def "main apply" [] {
  if not ($cfg.peersFile | path exists) {
    print -e $"No ($cfg.peersFile); leaving ($cfg.interface) alone."
    return
  }
  let want = (load_peers)
  let live = (try { wg show $cfg.interface peers | lines | where {|l| $l != "" } } catch { [] })
  for p in $want { wg set $cfg.interface peer $p.publicKey allowed-ips $"($p.ip)/32" }
  let keys = ($want | get -o publicKey | default [])
  for k in $live { if not ($k in $keys) { wg set $cfg.interface peer $k remove } }
  print -e $"Applied ($want | length) peers."
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
  let peers = (load_peers)
  # Live but unregistered means a hand-run `wg set` or a peer file restored from an older backup.
  let stray = ($dump | columns | where {|k| not ($k in ($peers | get -o publicKey | default [])) })
  if not ($stray | is-empty) { print -e $"Live but unregistered, apply drops them: ($stray | str join ', ')" }
  if ($peers | is-empty) { print "No peers"; return }
  let now = ((date now | into int) // 1_000_000_000)
  $peers | each {|p|
    let hs = ($dump | get -o $p.publicKey | default 0)
    let ago = (if $hs > 0 { [($now - $hs) 0] | math max } else { null })
    {
      peer: $p.name
      ip: $p.ip
      access: (if (in_subnet $p.ip $cfg.fullAccessSubnet) { "lan" } else { "server" })
      added: ($p.added? | default "?")
      handshake: (if $raw == null { "unknown"
        } else if $ago == null { "never"
        } else if $ago < 60 { $"($ago)s ago"
        } else if $ago < 3600 { $"($ago // 60)m ago"
        } else if $ago < 86400 { $"($ago // 3600)h ago"
        } else { $"($ago // 86400)d ago" })
    }
  }
  # Nothing reports a width off a terminal, and the default renderer gives up rather than printing.
  | if (term size).columns == 0 { table --width 100 } else { $in }
}

def main [] {
  print "wg-manage - WireGuard peers (runtime state in the peer file, applied live, no deploy)

  add <name> [--full-access] [--conf]   Mint a keypair, bring the peer up, render its QR
  remove <name>                         Cut a peer and forget it
  status                                Peers, tier, when added, last handshake, plus strays
  apply                                 Re-sync the peer file onto the interface; runs at boot

  --full-access allocates from the full-access block, which reaches the LAN. Every other address
  reaches the server's restricted ports only. Anything these cannot do, edit the peer file and
  run `apply`."
}
