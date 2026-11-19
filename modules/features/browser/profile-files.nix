# Profile files Zen rewrites itself, kept as dotfiles in <profile>/declared/ and applied while Zen
# is closed: at activation and at login, before the session starts. A missing file leaves Zen's
# alone. Each holds the shape of the Zen file it goes into:
#   containers.json     containers.json, replaces it
#   search.json         search.json without the default engines' hashes, which it gets here;
#                       replaces search.json.mozlz4
#   sessions.json       {spaces, tabs, folders, groups}: rows of zen-sessions.jsonlz4, merged by
#                       uuid, zenSyncId and id. With spaces, the ones not listed go; with tabs,
#                       pinned tabs not listed become normal tabs after the listed ones. Only into
#                       a file Zen has made
#   live-folders.json   rows of zen-live-folders.jsonlz4, merged by id; Zen keeps its own state.
#                       Only once the sessions file exists
#   space-routing.json  {routes, defaultRouteExternal} of zen-space-routing.jsonlz4, routes merged
#                       by id
#   storage-sync/<extension id>.json
#                       merged over that extension's blob in storage-sync-v2.sqlite (storage.sync);
#                       DeArrow's licenseKey there is its free key, not a secret
# The last two become Zen's file as they are where it has none. The merges are the zen-browser
# flake's (hm-module/session) without split views, reading these files instead of its options.
{ lib, ... }:
{
  flake.modules.homeManager.browser =
    { config, pkgs, ... }:
    let
      inherit (config.programs.zen-browser) profilesPath;

      # jq filters for merge below; each reads the declared file as $d. upsert keeps the rows of .
      # in their order, puts a declared row's fields (f over [row, declared]) over the row with its
      # key, then appends the declared rows that are new
      filter =
        name: body:
        pkgs.writeText "zen-${name}.jq" ''
          def upsert($decl; key; f):
            [.[] | key] as $have
            | map(. as $e | ([$decl[] | select(key == ($e | key))] | first) as $o
                | if $o != null then [$e, $o] | f else . end)
            + [$decl[] | select(key as $k | $have | index($k) | not)];
          $d[0] as $d
          | ${body}
        '';

      sessions = filter "sessions" ''
        .spaces = (.spaces // []) | .tabs = (.tabs // [])
        | .folders = (.folders // []) | .groups = (.groups // [])
        | if $d.spaces then
            .spaces |= (upsert($d.spaces; .uuid; .[0] * .[1])
              | map(select(.uuid as $u | [$d.spaces[].uuid] | index($u) != null)))
          else . end
        | if $d.tabs then
            [$d.tabs[].zenSyncId] as $dpIds
            | .tabs |= upsert($d.tabs; .zenSyncId; .[0] * (.[1]
                | {pinned, zenEssential, zenWorkspace, userContextId, index, entries, groupId, zenStaticLabel}
                  + (if .id != null then {id} else {} end)))
            # per space: listed pins by index, then unlisted pins unpinned, then normal tabs
            | .tabs = (
                .tabs as $allTabsIn |
                ($allTabsIn | to_entries) as $ent |
                ($ent | group_by(.value.zenWorkspace // "") | map(sort_by(.key))
                | map(
                    . as $ws |
                    ($ws | map(select((.value.pinned == true or .value.zenEssential == true) and (.value.zenSyncId as $id | $dpIds | index($id) != null)))) as $declaredEnt |
                    ($ws | map(select((.value.pinned == true or .value.zenEssential == true) and (.value.zenSyncId as $id | $dpIds | index($id) == null)))) as $orphanEnt |
                    ($ws | map(select((.value.pinned != true) and (.value.zenEssential != true)))) as $normalEnt |
                    (($declaredEnt | sort_by(.value.index // 0)) | map(.value)) as $decl |
                    (($orphanEnt | sort_by(.key)) | map(.value | . * {pinned: false, zenEssential: false, groupId: null})) as $dem |
                    (($normalEnt | sort_by(.key)) | map(.value)) as $norm |
                    $decl + $dem + $norm
                  )
                | flatten
              )
            )
            | .tabs = [.tabs | to_entries[] | .value * {index: .key}]
          else . end
        | .folders |= upsert($d.folders // []; .id; .[0] * .[1])
        | .groups |= upsert($d.groups // []; .id;
            (.[1].splitView == true) as $split | .[0] * .[1] | if $split then del(.index) else . end)
        | .folders |= sort_by(.index // 0)
        | .groups |= sort_by(.index // 0)
      '';

      # Zen keeps a live folder's dismissed items and tab state
      liveFolders = filter "live-folders" ''
        (if type == "array" then . else [] end)
        | upsert($d; .id; .[0] * (.[1] | del(.dismissedItems, .tabsState)))
      '';

      routing = filter "space-routing" ''
        (if type == "object" then . else {} end) as $existing
        | {
            routes: (($existing.routes // []) | upsert($d.routes // []; .id; .[0] * .[1])),
            defaultRouteExternal: (if $d | has("defaultRouteExternal") then $d.defaultRouteExternal
              else ($existing.defaultRouteExternal // "most-recent-space") end)
          }
      '';

      load = pkgs.writeShellApplication {
        name = "zen-declared";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.jq
          pkgs.lsof
          pkgs.mozlz4a
          pkgs.openssl
          pkgs.sqlite
        ];
        text = ''
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
            if [ ! -f "$target" ] && [ "''${4-}" != new ]; then
              return 0
            fi
            tmp=$(mktemp "$target.XXXXXX")
            if [ -f "$target" ]; then
              mozlz4a -d "$target" - | jq --slurpfile d "$file" -f "$3" | mozlz4a - "$tmp" && ok=1
            else
              mozlz4a "$file" "$tmp" && ok=1
            fi
            if [ -n "''${ok-}" ]; then
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
            cur=''${cur//\'/\'\'}
            sqlite3 "$db" "update storage_sync_data set data = '$cur' where ext_id = '$1';" \
              || echo "zen: storage.sync of $1 could not be written" >&2
          }

          for profile in "$1"/*/; do
            profile=''${profile%/}
            name=$(basename -- "$profile")
            declared=$profile/declared
            [ -d "$declared" ] || continue

            if lsof -- "$profile/.parentlock" >/dev/null 2>&1; then
              echo "zen: $profile is in use; close Zen, its declared files apply at the next login"
              continue
            fi

            # each file is written to a temporary one next to its target and renamed, so Zen never
            # reads half a file
            file=$declared/containers.json
            if [ -f "$file" ]; then
              if jq -e . "$file" >/dev/null; then
                tmp=$(mktemp "$profile/containers.json.XXXXXX")
                cp -- "$file" "$tmp"
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

            merge sessions.json zen-sessions.jsonlz4 ${sessions}
            # live folders need their rows in the sessions file
            if [ -f "$profile/zen-sessions.jsonlz4" ]; then
              merge live-folders.json zen-live-folders.jsonlz4 ${liveFolders} new
            fi
            merge space-routing.json zen-space-routing.jsonlz4 ${routing} new

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
        '';
      };
    in
    {
      # after the dotfiles, which a fresh install links in that same activation
      home.activation.zenDeclared = config.lib.dag.entryAfter [ "linkGeneration" "dotfiles" ] ''
        ${lib.getExe load} ${lib.escapeShellArg profilesPath} || true
      '';

      systemd.user.services.zen-declared = {
        Unit = {
          Description = "Copy Zen's declared profile files in";
          Before = [ "graphical-session-pre.target" ];
        };
        Install.WantedBy = [ "graphical-session-pre.target" ];
        Service = {
          Type = "oneshot";
          ExecStart = "${lib.getExe load} ${lib.escapeShellArg profilesPath}";
        };
      };
    };
}
