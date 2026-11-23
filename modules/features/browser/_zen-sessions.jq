# Read by modules/features/browser/profile-files.nix: merges sessions.json by uuid, zenSyncId and id.
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
# with folders, the ones not listed go, with their group; their tabs stay, outside a folder.
# Split views are groups Zen makes itself and stay
| if $d.folders then
    .folders |= (upsert($d.folders; .id; .[0] * .[1]) | only($d.folders; .id))
    | ([$d.folders[].id] + [$d.groups[]?.id]) as $keep
    | .groups |= map(select(.splitView == true or (.id as $g | $keep | index($g) != null)))
    | [.groups[].id] as $groups
    | .tabs |= map(if .groupId != null and (.groupId as $g | $groups | index($g) == null)
        then .groupId = null else . end)
  else . end
| .groups |= upsert($d.groups // []; .id;
    (.[1].splitView == true) as $split | .[0] * .[1] | if $split then del(.index) else . end)
| .folders |= sort_by(.index // 0)
| .groups |= sort_by(.index // 0)
