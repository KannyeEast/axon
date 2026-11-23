# Read by modules/features/browser/profile-files.nix: merges live-folders.json by id, the rest go.
(if type == "array" then . else [] end)
# Zen keeps dismissed items and tab state
| upsert($d; .id; .[0] * (.[1] | del(.dismissedItems, .tabsState)))
| only($d; .id)
