# Read by modules/features/browser/profile-files.nix: zen-declared <profiles folder> [wait].

# Zen ignores a default engine whose hash doesn't match: sha256 over the profile folder's
# name, the engine id and this text with the app's name in it
disclaimer="By modifying this file, I agree that I am doing so only within Zen itself, using official, user-driven search engine selection processes, and in a way which does not circumvent user consent. I acknowledge that any attempt to change this file from outside of Zen is a malicious act, and will be responded to accordingly."
hash() { printf '%s' "$name$1$disclaimer" | openssl dgst -sha256 -binary | base64; }

# merge declared/$1 into the compressed $2 with jq filter file $3; a missing $2 is the
# declared file as it is when $4 is "new", else left to Zen
merge() {
  local file=$declared/$1 target=$profile/$2 tmp ok
  [ -f "$file" ] || return 0
  if ! jq -e . "$file" >/dev/null; then
    echo "zen: $file is not valid JSON, skipped" >&2
    return 0
  fi
  if [ ! -f "$target" ] && [ "${4-}" != new ]; then
    return 0
  fi
  tmp=$(mktemp "$target.XXXXXX")
  if [ -f "$target" ]; then
    mozlz4a -d "$target" - | jq --slurpfile d "$file" -f "$3" | mozlz4a - "$tmp" && ok=1
  else
    mozlz4a "$file" "$tmp" && ok=1
  fi
  if [ -n "${ok-}" ]; then
    mv -f -- "$tmp" "$target"
  else
    rm -f -- "$tmp"
    echo "zen: $file could not be applied to $target" >&2
  fi
}

# merge JSON $2 over the storage.sync blob of extension $1, which it must have made
sync() {
  local db=$profile/storage-sync-v2.sqlite cur
  cur=$(sqlite3 "$db" "select data from storage_sync_data where ext_id = '$1';") || true
  if [ -z "$cur" ]; then
    echo "zen: no storage.sync data for $1 yet, skipped"
    return 0
  fi
  cur=$(jq -c --argjson d "$2" '. * $d' <<<"$cur")
  # quotes doubled for SQL
  cur=${cur//\'/\'\'}
  sqlite3 "$db" "update storage_sync_data set data = '$cur' where ext_id = '$1';" \
    || echo "zen: storage.sync of $1 could not be written" >&2
}

for profile in "$1"/*/; do
  profile=${profile%/}
  name=$(basename -- "$profile")
  declared=$profile/declared
  [ -d "$declared" ] || continue

  if [ "${2-}" = wait ]; then
    while lsof -- "$profile/.parentlock" >/dev/null 2>&1; do sleep 5; done
  elif lsof -- "$profile/.parentlock" >/dev/null 2>&1; then
    echo "zen: $profile is in use; close Zen, its declared files apply at the next login"
    continue
  fi

  # each file is written to a temporary one next to its target and renamed, so Zen never
  # reads half a file
  file=$declared/containers.json
  if [ -f "$file" ]; then
    if jq -e . "$file" >/dev/null; then
      tmp=$(mktemp "$profile/containers.json.XXXXXX")
      # Zen numbers a new container lastUserContextId + 1; never below a declared one
      jq '.lastUserContextId = ([.lastUserContextId // 0, (.identities[] | select(.public) | .userContextId)] | max)' "$file" >"$tmp"
      mv -f -- "$tmp" "$profile/containers.json"
    else
      echo "zen: $file is not valid JSON, skipped" >&2
    fi
  fi

  file=$declared/search.json
  if [ -f "$file" ]; then
    if ids=$(jq -r '.metaData | .defaultEngineId // "", .privateDefaultEngineId // ""' "$file"); then
      { read -r default; read -r private; } <<<"$ids"
      tmp=$(mktemp "$profile/search.json.mozlz4.XXXXXX")
      mozlz4a <(jq --arg d "$(hash "$default")" --arg p "$(hash "$private")" '
        if .metaData.defaultEngineId then .metaData.defaultEngineIdHash = $d else . end
        | if .metaData.privateDefaultEngineId then .metaData.privateDefaultEngineIdHash = $p else . end
      ' "$file") "$tmp"
      mv -f -- "$tmp" "$profile/search.json.mozlz4"
    else
      echo "zen: $file is not valid JSON, skipped" >&2
    fi
  fi

  # only into a file Zen has made
  merge sessions.json zen-sessions.jsonlz4 "$SESSIONS_JQ"
  # live folders need their rows in the sessions file
  if [ -f "$profile/zen-sessions.jsonlz4" ]; then
    merge live-folders.json zen-live-folders.jsonlz4 "$LIVE_FOLDERS_JQ" new
  fi
  merge space-routing.json zen-space-routing.jsonlz4 "$ROUTING_JQ" new

  if [ -f "$profile/storage-sync-v2.sqlite" ]; then
    for file in "$declared"/storage-sync/*.json; do
      [ -f "$file" ] || continue
      if json=$(jq -c . "$file"); then
        sync "$(basename -- "$file" .json)" "$json"
      else
        echo "zen: $file is not valid JSON, skipped" >&2
      fi
    done
    # SponsorBlock and DeArrow share one userID
    uid=$(sqlite3 "$profile/storage-sync-v2.sqlite" \
      "select data from storage_sync_data where ext_id = 'sponsorBlocker@ajay.app';" \
      | jq -r '.userID // empty') || true
    if [ -n "$uid" ]; then
      sync deArrow@ajay.app "$(jq -cn --arg u "$uid" '{userID: $u}')"
    fi
  fi
done
