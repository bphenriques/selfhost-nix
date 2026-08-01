#!/usr/bin/env nu
# Bootstrap only. Bazarr rewrites config.yaml at runtime, so it can never be a store symlink — and the two
# keys below have to exist *before* the process starts: the listen address (there is no CLI flag for it) and
# the API key the reconcile authenticates with (Bazarr would otherwise invent a random one we cannot know).
# Everything else is reconciled through the API afterwards; this script must not grow.
let config_file = $env.BAZARR_CONFIG_FILE
let api_key = open $env.BAZARR_API_KEY_FILE | str trim

mkdir ($config_file | path dirname)

# Bazarr creates the file empty on first run, so "exists" is not the same as "parseable".
let current = if ($config_file | path exists) {
  try {
    open $config_file --raw | from yaml | default {}
  } catch { {} }
} else {
  {}
}

let current = if ($current | describe | str starts-with "record") { $current } else { {} }

let general = ($current | get -o general | default {}) | merge {
  ip: "127.0.0.1"  # no --ip flag exists; ingress is the only intended entrypoint
}

# auth.type null = no login page: forward-auth in front of the app is the gate.
let auth = ($current | get -o auth | default {}) | merge { apikey: $api_key, type: null }
let updated = $current | merge { general: $general, auth: $auth }
if $updated == $current {
  print "config.yaml already seeded"
  exit 0
}

$updated | to yaml | save --force $config_file
print $"Seeded ($config_file)"
