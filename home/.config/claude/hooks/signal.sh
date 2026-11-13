#!/usr/bin/env bash
# Writes this Claude session's state to ~/.claude/signal/ for the Stream Deck daemon outside the
# sandbox. Called by settings.json's hooks with the hook's JSON on stdin and one argument: the new
# state (working, needs, waiting, error), `end`, or `agent-start`/`agent-stop` for a subagent.
# One file per session and per running subagent, replaced atomically.
set -euo pipefail

dir="$HOME/.claude/signal"
mkdir -p "$dir/sessions" "$dir/agents"
input=$(cat)
field() { jq -r --arg f "$1" '.[$f] // empty' <<<"$input"; }
session=$(field session_id)
[ -n "$session" ] || exit 0
# named like the tmux session `work` makes for the folder, which the deck finds the window by;
# the project's folder, not cwd, which follows a cd
project=$(basename "${CLAUDE_PROJECT_DIR:-$(field cwd)}")
project=${project//[.:]/_}

write() {
  local tmp
  tmp=$(mktemp "$1.XXXXXX")
  cat >"$tmp"
  mv -f "$tmp" "$1"
}

case "$1" in
  end)
    rm -f "$dir/sessions/$session.json"
    grep -l "\"session\": *\"$session\"" "$dir"/agents/*.json 2>/dev/null | xargs -r rm -f || true
    ;;
  agent-start | agent-stop)
    agent=$(field agent_id)
    [ -n "$agent" ] || exit 0
    if [ "$1" = agent-stop ]; then
      rm -f "$dir/agents/$agent.json"
    else
      jq -n --arg session "$session" --arg type "$(field agent_type)" --arg project "$project" \
        '{session: $session, type: $type, project: $project, since: now | floor}' | write "$dir/agents/$agent.json"
    fi
    ;;
  *)
    # started stays from the session's first state, so its key keeps its place on the deck
    file="$dir/sessions/$session.json"
    started=$(jq -r '.started // empty' "$file" 2>/dev/null || true)
    jq -n --arg state "$1" --arg project "$project" --arg started "$started" \
      '{state: $state, project: $project, since: now | floor, started: ($started | tonumber? // (now | floor))}' \
      | write "$file"
    ;;
esac
