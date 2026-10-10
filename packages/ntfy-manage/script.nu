#!/usr/bin/env nu
# Two halves, kept apart by ntfy's own `provisioned` flag.
#
# Publishers and topic visibility are declared in Nix: `provision` renders them into the auth env file
# and the server reconciles them on every start, wiping its provisioned rows and rebuilding from the
# config. Nothing accretes, and dropping a publisher revokes it.
#
# Readers are people, so they are created here against the live auth DB and the reconciler never sees
# them. `ntfy user`/`ntfy access` run with provisioning disabled upstream, which is what makes the two
# halves safe to mix.
let cfg = open $env.NTFY_MANAGE_CONFIG

def require_root [] {
  if (^id -u | into int) != 0 { error make {msg: "ntfy-manage needs root; re-run with sudo"} }
}

def topic_names [] { $cfg.topics | columns }
def private_topics [] { $cfg.topics | transpose name spec | where {|t| not $t.spec.public } | get name }
def public_topics [] { $cfg.topics | transpose name spec | where {|t| $t.spec.public } | get name }
def publisher_names [] { $cfg.publishers | columns }

# Names Nix owns. A reader taking one of these would be adopted by the next reconcile, which rewrites
# its role and password out from under it.
def declared_names [] { (publisher_names) | append "admin" }

# `ntfy user hash` is interactive-only and asks twice; off a pipe it falls back to reading two lines.
def hash_password [password: string] {
  $"($password)\n($password)\n" | ntfy user hash | str trim
}

def write_private [path: string, content: string] {
  let tmp = $"($path).tmp"
  $content | save --raw --force $tmp
  chmod 0400 $tmp
  chown "root:root" $tmp
  mv --force $tmp $path
}

# The token is the publisher's only credential, so it has to survive restarts: consumers read this path
# directly or via LoadCredential and never learn a new value on their own.
def existing_or_new_token [path: string] {
  if ($path | path exists) {
    open --raw $path | str trim
  } else {
    let token = (ntfy token generate | str trim)
    write_private $path $token
    print $"  minted token for ($path | path basename)"
    $token
  }
}

# Reported, not deleted. Removing the file would not revoke anything: the account it belongs to is only
# reconciled if ntfy provisioned it, and a hand-made one keeps working while its sole token copy is gone.
# This runs unattended on every boot, so it is the wrong place to destroy a credential.
def report_orphan_tokens [declared_files: list<string>] {
  if not ($cfg.tokenDir | path exists) { return }
  let orphans = (
    ls --short-names $cfg.tokenDir | where type == file | get name
    | each {|n| [$cfg.tokenDir $n] | path join }
    | where {|p| $p not-in $declared_files }
  )
  if ($orphans | is-not-empty) {
    print --stderr $"WARNING: token files with no declared publisher: ($orphans | each {|p| $p | path basename } | str join ', ')"
    print --stderr "  Left in place: deleting one revokes nothing. Drop the account with `ntfy user del <name>` first."
  }
}

def all_users [] {
  ntfy access | lines | parse --regex '^user (?<name>\S+) \(role: (?<role>\w+)'
}

def reader_names [] {
  all_users | where role == "user" | get name | where {|n| $n not-in (declared_names) }
}

def grants_for [name: string] {
  ntfy access $name | lines | parse --regex '^- (?<permission>[\w-]+) access to topic (?<topic>\S+)'
}

# --- Systemd: render the declarative half ---
def "main provision" [] {
  require_root
  print "Provisioning ntfy auth..."

  # Admin exists for the web UI and the HTTP admin API. It carries no grants: ntfy refuses access
  # entries on admin-role users, which is why a person reading private topics needs a reader instead.
  mut users = [$"admin:(hash_password (open --raw $cfg.adminPasswordFile | str trim)):admin"]
  mut access = []
  mut tokens = []
  mut token_files = []

  for entry in ($cfg.publishers | transpose name pub) {
    # Publishers authenticate by token, so the password is a value nobody keeps: minted here, hashed,
    # and dropped unrecorded. There is no plaintext to leak and nothing to rotate.
    $users = ($users | append $"($entry.name):(hash_password (random chars --length 32)):user")
    $tokens = ($tokens | append $"($entry.name):(existing_or_new_token $entry.pub.tokenFile):($entry.name)")
    $token_files = ($token_files | append $entry.pub.tokenFile)
    for topic in $entry.pub.topics {
      $access = ($access | append $"($entry.name):($topic):wo")
    }
  }

  # Only public topics get an anonymous grant. A private topic is declared by omission, which is what
  # makes flipping `public` back off a revocation rather than a no-op.
  for topic in (public_topics) { $access = ($access | append $"everyone:($topic):ro") }

  report_orphan_tokens $token_files

  write_private $cfg.authEnvFile ([
    $"NTFY_AUTH_USERS=($users | str join ',')"
    $"NTFY_AUTH_ACCESS=($access | str join ',')"
    $"NTFY_AUTH_TOKENS=($tokens | str join ',')"
  ] | str join "\n" | $in + "\n")

  print $"Declared ($cfg.publishers | columns | length) publishers over ($access | length) grants."
}

# --- Runtime: readers ---
def "main reader add" [
  name: string
  --topics: string  # comma-separated; defaults to every private topic
] {
  require_root
  if $name in (declared_names) {
    error make {msg: $"($name) is declared in Nix; the next reconcile would take the name back"}
  }
  let wanted = if ($topics | is-empty) { private_topics } else { $topics | split row "," | each {|t| $t | str trim } }
  let unknown = ($wanted | where {|t| $t not-in (topic_names) })
  if ($unknown | is-not-empty) {
    error make {msg: $"No such topic: ($unknown | str join ', '). Declared: ((topic_names) | str join ', ')"}
  }
  if ($wanted | is-empty) { error make {msg: "No private topics to grant"} }

  let password = (random chars --length 24)
  with-env { NTFY_PASSWORD: $password } { ntfy user add --role=user $name }
  for t in $wanted { ntfy access $name $t ro }

  print $"($name) can read: ($wanted | str join ', ')"
  print $"password: ($password)"
  print -e "Shown once. Losing it means removing and adding the reader again."
}

def "main reader remove" [name: string] {
  require_root
  if $name in (declared_names) {
    error make {msg: $"($name) is declared in Nix, not a runtime reader"}
  }
  ntfy user del $name
  print $"Removed ($name); its grants and tokens went with it."
}

def "main status" [] {
  require_root
  let known = (all_users | get name)
  print "Topics"
  print ($cfg.topics | transpose topic spec | each {|t|
    {topic: $t.topic, read: (if $t.spec.public { "anyone" } else { "readers only" })}
  } | table --width 200)

  print "\nPublishers (Nix, reconciled every start)"
  print ($cfg.publishers | transpose name pub | each {|p|
    {publisher: $p.name, writes: ($p.pub.topics | str join ", ")}
  } | table --width 200)

  let runtime = (reader_names)
  print "\nReaders (runtime)"
  if ($runtime | is-empty) {
    print "None. `ntfy-manage reader add <name>` grants every private topic."
  } else {
    print ($runtime | each {|r|
      {reader: $r, grants: (grants_for $r | each {|g| $"($g.topic) ($g.permission)" } | str join ", ")}
    } | table --width 200)
  }

  # The reconcile only deletes rows it provisioned, so anything from an older config survives it. Both
  # shapes are reported rather than removed: one of them is indistinguishable from a reader.
  let writers = ($runtime | where {|r| (grants_for $r | any {|g| $g.permission != "read-only" }) })
  if ($writers | is-not-empty) {
    print -e $"\nWARNING: runtime accounts holding write access: ($writers | str join ', ')"
    print -e "  Publishers from an older config, not readers. Remove with `ntfy user del <name>`."
  }

  let mismatched = ($cfg.publishers | columns | where {|n| $n in $known } | where {|n|
    (grants_for $n | get topic | sort) != ($cfg.publishers | get $n | get topics | sort)
  })
  if ($mismatched | is-not-empty) {
    print -e $"\nWARNING: grants differ from config for: ($mismatched | str join ', ')"
    print -e "  A topic this publisher was retargeted away from. Clear with `ntfy access --reset <user> <topic>`."
  }
}

def main [] {
  print "ntfy-manage - ntfy auth (publishers declarative, readers runtime)

  status                                  Topics, publishers, readers, and grants that differ from config
  reader add <name> [--topics a,b]        Create a reader over the private topics, print its password once
  reader remove <name>                    Delete a reader, with its grants and tokens
  provision                               Render the declarative auth env file; runs before ntfy starts

  Publishers and topic visibility come from Nix and are reconciled by ntfy on every start. Readers are
  runtime state this tool owns; removing one revokes it immediately, with no deploy."
}
