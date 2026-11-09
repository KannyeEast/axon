#!/usr/bin/env bash
# Prints the open findings of the latest review on the pull request into stable: the summary,
# then file:line and text per unresolved comment. For the owner (`just findings`) and the author
# assistant, who fixes them. FORGE (https://host/owner/repo) and API come from the justfile.
set -euo pipefail

: "${FORGE:?} ${API:?}"

token=${FORGEJO_TOKEN:-$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/forgejo/token" 2>/dev/null || true)}
auth=()
if [ -n "$token" ]; then auth=(-H "Authorization: token $token"); fi
call() { curl --silent --show-error --fail-with-body "${auth[@]}" "$@"; }
number=$(call "$API/pulls?state=open&limit=50" \
  | jq '[.[] | select(.base.ref == "stable" and .head.ref == "dev")][0].number // empty')
if [ -z "$number" ]; then echo "No open pull request into stable."; exit 0; fi
review=$(call "$API/pulls/$number/reviews" | jq 'map(select(.user.login == "forgejo-actions")) | last // empty')
if [ -z "$review" ]; then echo "$FORGE/pulls/$number has no review yet."; exit 0; fi
jq -r '"\(.state) on \(.commit_id[0:7])\(if .stale then ", older than the pull request" else "" end)\n\(.body)\n"' <<<"$review"
call "$API/pulls/$number/reviews/$(jq .id <<<"$review")/comments" | jq -r '.[] | select(.resolver == null)
  | "\(.path):\(if .position > 0 then .position else "\(.original_position) (removed line)" end)\n\(.body)\n"'
