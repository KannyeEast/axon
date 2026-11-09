#!/usr/bin/env bash
# Writes what this Claude session is doing to ~/.claude/signal/, for things outside the sandbox
# (the Stream Deck daemon) to show. Called by the hooks in settings.json with the hook's JSON on
# stdin and one argument: the session's new state (working, needs, waiting, error), `end`, or
# `agent-start`/`agent-stop` for a subagent. One file per session and per running subagent,
# replaced atomically, so a reader never sees half a file.
set -euo pipefail

dir="$HOME/.claude/signal"
mkdir -p "$dir/sessions" "$dir/agents"
input=$(cat)
field() { jq -r --arg f "$1" '.[$f] // empty' <<<"$input"; }
session=$(field session_id)
[ -n "$session" ] || exit 0

write() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX")
  cat >"$tmp"
  mv -f "$tmp" "$1"
}

case "$1" in
  end)
    rm -f "$dir/sessions/$session.json"
    grep -l "\"session\": *\"$session\"" "$dir"/agents/*.json 2>/dev/null | xargs -r rm -f
    ;;
  agent-start | agent-stop)
    agent=$(field agent_id)
    [ -n "$agent" ] || exit 0
    if [ "$1" = agent-stop ]; then
      rm -f "$dir/agents/$agent.json"
    else
      jq -n --arg session "$session" --arg type "$(field agent_type)" --arg project "$(basename "$(field cwd)")" \
        '{session: $session, type: $type, project: $project, since: now | floor}' | write "$dir/agents/$agent.json"
    fi
    ;;
  *)
    jq -n --arg state "$1" --arg project "$(basename "$(field cwd)")" --arg cwd "$(field cwd)" \
      '{state: $state, project: $project, cwd: $cwd, since: now | floor}' | write "$dir/sessions/$session.json"
    ;;
esac
