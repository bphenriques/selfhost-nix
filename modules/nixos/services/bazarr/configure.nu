#!/usr/bin/env nu
# Idempotent Bazarr reconcile. Everything Bazarr owns lives behind one endpoint: POST /api/system/settings
# writes both config.yaml and the language-profile table, so the whole reconcile is a single form post.
# Subtitle providers are acquisition config — they arrive from the caller's `settings`, and no provider is
# named anywhere in the framework.
let base_url = $env.BAZARR_URL
let api_key = open $env.BAZARR_API_KEY_FILE | str trim
let config = open $env.BAZARR_CONFIG_FILE
let headers = [X-API-KEY, $api_key]

def wait_ready [] {
  for attempt in 1..30 {
    print $"Waiting for Bazarr... ($attempt)"
    let r = try { http get $"($base_url)/api/system/ping" --full --allow-errors } catch { null }
    if $r != null and $r.status == 200 { return }
    sleep 2sec
  }
  error make {msg: "Bazarr failed to start after 30 attempts"}
}

def get_json [path: string] {
  let r = http get $"($base_url)($path)" --headers $headers --full --allow-errors
  if $r.status != 200 { error make {msg: $"GET ($path) failed: ($r.status) - ($r.body)"} }
  $r.body
}

# Reuse the existing profileId when a profile of the same name is already there, so re-running does not
# orphan the series/movies already pointing at it. Any profile we no longer declare is dropped: the API
# treats the posted list as the complete set.
def build_profiles [existing: list<any>] {
  let declared = $config | get -o languageProfiles | default []
  $declared | enumerate | each { |it|
    let profile = $it.item
    let previous = $existing | where name == $profile.name | get 0?
    # Per-item flags are Python-flavoured strings here, unlike the "true"/"false" of top-level form values.
    let items = $profile.languages | enumerate | each { |l| {
      id: ($l.index + 1)
      language: $l.item
      audio_exclude: "False", 
      audio_only_include: "False", 
      forced: "False", 
      hi: "False"
    } }
    # cutoff names the language that ends the search; null means "keep looking for every language".
    let cutoff = if ($profile | get -o cutoff) == null { null } else {
      let match = $items | where language == $profile.cutoff | get 0?
      if $match == null {
        error make {msg: $"Profile '($profile.name)': cutoff '($profile.cutoff)' is not one of its languages"}
      }
      $match.id
    }
    {
      profileId: (if $previous == null { $it.index + 1 } else { $previous.profileId })
      name: $profile.name
      cutoff: $cutoff
      items: $items
      mustContain: []
      mustNotContain: []
      originalFormat: false
      tag: null
    }
  }
}

# settings-<section>-<key>, the shape save_settings() parses. Lists are repeated keys, which is what
# `url build-query` emits and what request.form.getlist() expects.
def settings_form [section: string, values: record] {
  $values | transpose key value | reduce --fold {} { |it, acc|
    let v = if ($it.value | describe) == "bool" {
      if $it.value { "true" } else { "false" }
    } else {
      $it.value
    }
    $acc | insert $"settings-($section)-($it.key)" $v
  }
}

def arr_form [name: string] {
  let arr = $config | get -o $name
  if $arr == null { return ({} | insert $"settings-general-use_($name)" "false") }
  let key = open $arr.apiKeyFile | str trim
  {}
  | insert $"settings-general-use_($name)" "true"
  | merge (settings_form $name {
      ip: $arr.host
      port: $arr.port
      base_url: $arr.baseUrl
      ssl: false
      apikey: $key
    })
}

def main [] {
  wait_ready
  print "Bazarr is ready"

  let existing = get_json "/api/system/languages/profiles"
  let profiles = build_profiles $existing
  let languages = $profiles | get items | flatten | get language | uniq

  let default_profile = $config | get -o defaultProfile
  let default_id = if $default_profile == null { null } else {
    let match = $profiles | where name == $default_profile | get 0?
    if $match == null { error make {msg: $"defaultProfile '($default_profile)' is not a declared profile"} }
    $match.profileId
  }
  # Applied to newly-added media only; existing series/movies keep whatever they already have.
  let defaults = if $default_id == null { {} } else {
    settings_form "general" {
      serie_default_enabled: true
      serie_default_profile: $default_id
      movie_default_enabled: true
      movie_default_profile: $default_id
    }
  }

  # Secrets are read here rather than baked into the config: the Nix store is world-readable.
  let secrets = ($config | get -o secretSettings | default {}) | transpose key file | reduce --fold {} { |it, acc|
    $acc | insert $"settings-($it.key | str replace '.' '-')" (open $it.file | str trim)
  }

  let extra = ($config | get -o settings | default {}) | transpose section values | reduce --fold {} { |it, acc|
    $acc | merge (settings_form $it.section $it.values)
  }

  let form = {}
  | merge (arr_form "sonarr")
  | merge (arr_form "radarr")
  | merge {"languages-enabled": $languages}
  | merge (if ($profiles | is-empty) { {} } else { {
    "languages-profiles": ($profiles | to json --raw)
  } })
  | merge $defaults
  | merge $extra
  | merge $secrets

  print $"Applying ($form | columns | length) settings, ($profiles | length) language profile\(s\)..."
  # Encoded by hand and sent as a raw body: `--content-type application/x-www-form-urlencoded` rejects the
  # list values, while Bazarr reads several of these keys with getlist() and so needs the repeated form
  # `url build-query` produces.
  let body = $form | url build-query
  let post_headers = $headers ++ [Content-Type "application/x-www-form-urlencoded"]
  let r = http post $"($base_url)/api/system/settings" $body --headers $post_headers --full --allow-errors
  if $r.status not-in [200, 204] { error make {msg: $"Failed to apply settings: ($r.status) - ($r.body)"} }

  # Verify rather than trust: a 204 only means the form parsed, not that the profile landed.
  let applied = get_json "/api/system/languages/profiles"
  for p in $profiles {
    if ($applied | where name == $p.name | is-empty) {
      error make {msg: $"Language profile '($p.name)' missing after apply"}
    }
  }
  print "Bazarr reconcile complete"
}
