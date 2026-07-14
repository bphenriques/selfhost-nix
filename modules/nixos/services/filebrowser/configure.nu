#!/usr/bin/env nu
# Reconciles FileBrowser proxy-auth + per-user scopes/permissions from the seed JSON; rebuilds the DB only when it changed.
let config = open $env.FILEBROWSER_CONFIG_FILE

def fb [...args] {
  let r = filebrowser -d $env.FILEBROWSER_DB ...$args | complete
  if $r.exit_code != 0 {
    error make {msg: $"filebrowser failed: ($args | str join ' ')\n($r.stderr)"}
  }
  $r.stdout
}

# --name=value, but only when value is non-null (optional personal settings)
def flag [name: string, value] {
  if $value == null { [] } else { [$"--($name)=($value)"] }
}
def branding_flags [] {
  let s = $config.settings
  [
    (flag "branding.name" ($s.branding?.name?))
    (flag "branding.files" ($s.branding?.files?))
    (flag "branding.disableExternal" ($s.branding?.disableExternal?))
    (flag "branding.disableUsedPercentage" ($s.branding?.disableUsedPercentage?))
  ] | flatten
}
def view_flags [] {
  let s = $config.settings
  [
    (flag "viewMode" ($s.viewMode?))
    (flag "singleClick" ($s.singleClick?))
    (flag "hideDotfiles" ($s.hideDotfiles?))
    (flag "sorting.by" ($s.sorting?.by?))
    (flag "sorting.asc" ($s.sorting?.asc?))
  ] | flatten
}

def configure_defaults [] {
  let d = $config.access.defaults
  let p = $d.permissions
  let args = [
    $"--root=($env.FILEBROWSER_ROOT)" # seed-time scope resolution (e.g. /paulicia → root/paulicia)
    "--auth.method=proxy" $"--auth.header=($config.access.authHeader)"
    $"--scope=($d.scope)"
    $"--perm.create=($p.create)"
    $"--perm.delete=($p.delete)"
    $"--perm.rename=($p.rename)"
    $"--perm.modify=($p.modify)"
    $"--perm.execute=($p.execute)"
    $"--perm.share=($p.share)"
    $"--perm.download=($p.download)"
    "--perm.admin=false"
    "--signup=false" # pin security defaults rather than trust upstream
    "--disableExec=true"
    "--hideLoginButton"
  ] ++ (branding_flags) ++ (view_flags)
  fb config set ...$args
  print "Defaults configured"
}
def add_user [user: record] {
  let p = $user.permissions
  let user_args = [
    $"--scope=($user.scope)"
    $"--perm.admin=($user.admin)"
    $"--perm.create=($p.create)"
    $"--perm.delete=($p.delete)"
    $"--perm.rename=($p.rename)"
    $"--perm.modify=($p.modify)"
    $"--perm.execute=($p.execute)"
    $"--perm.share=($p.share)"
    $"--perm.download=($p.download)"
  ] ++ (view_flags)
  fb users add $user.username (random pass --chars 32) ...$user_args
  print $"  ($user.username): added"
}
# Rebuild from scratch so the DB is exactly the declared config (runs before FileBrowser; no live state).
def init_db [] {
  if ($env.FILEBROWSER_DB | path exists) { rm --force $env.FILEBROWSER_DB }
  fb config init
  print "Database initialized (fresh)"
}
# Reconcile only when the config changed (content-addressed); else keep the DB.
def main [] {
  let stamp = $"($env.FILEBROWSER_DB).stamp"
  let want = $env.FILEBROWSER_CONFIG_FILE
  let have = (
    if ($stamp | path exists) {
      open --raw $stamp | into string | str trim
    } else { "" }
  )
  if ($env.FILEBROWSER_DB | path exists) and ($have == $want) {
    print "Config unchanged; keeping the existing database"
    return
  }
  init_db
  configure_defaults
  print "Configuring users..."
  $config.access.users | each {|user| add_user $user } | ignore
  $want | save --force $stamp
  print "FileBrowser configuration complete"
}
