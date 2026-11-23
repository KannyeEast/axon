# Read by modules/features/browser/profile-files.nix: merges space-routing.json's routes by id.
(if type == "object" then . else {} end) as $existing
| {
    # with routes, the ones not listed go
    routes: (($existing.routes // [])
      | if $d.routes then upsert($d.routes; .id; .[0] * .[1]) | only($d.routes; .id) else . end),
    defaultRouteExternal: (if $d | has("defaultRouteExternal") then $d.defaultRouteExternal
      else ($existing.defaultRouteExternal // "most-recent-space") end)
  }
