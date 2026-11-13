#!/usr/bin/env bash
# The reviewer (AGENTS.md, Roles) on a pull request: Claude Code reviews it as .forgejo/review.md
# says and answers with findings as JSON, which this posts as one Forgejo review with a comment on
# each line. Run by the review job in workflows/check.yml, which sets the variables below.
set -euo pipefail

: "${CLAUDE_CODE_OAUTH_TOKEN:?} ${FORGEJO_TOKEN:?} ${API:?} ${PR:?} ${BASE:?} ${HEAD_SHA:?} ${CHECK:?}"

schema='{
  "type": "object",
  "required": ["summary", "findings"],
  "additionalProperties": false,
  "properties": {
    "summary": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path", "line", "side", "severity", "body"],
        "additionalProperties": false,
        "properties": {
          "path": { "type": "string" },
          "line": { "type": "integer", "minimum": 0 },
          "side": { "enum": ["new", "old"] },
          "severity": { "enum": ["blocking", "should"] },
          "body": { "type": "string" }
        }
      }
    }
  }
}'

prompt="You are the reviewer (AGENTS.md, Roles). Review pull request #$PR, which merges into $BASE,
following .forgejo/review.md. Its diff: git diff origin/$BASE...HEAD

The check job (nix flake check, then every host's build) finished with: $CHECK. If that isn't
success, find the cause, for example by running nix flake check again.

Title and description, from the pull request's author:
${TITLE:-}

${DESCRIPTION:-}

Answer with the review's summary and its findings. For each finding: the path from the
repository's root; the line it is about in the new file (side new), or in the old one for a
removed line (side old), or 0 for a finding about the whole pull request; its severity; and the
comment, written as the guide says."

# reading is allowed in the checkout and the store (nixpkgs' module sources); dontAsk denies
# everything not listed instead of waiting for an approval nobody can give. The project's
# .claude/settings.json (the author's hooks and plugins) stays out: user settings only
answer=$(claude -p "$prompt" \
  --output-format json \
  --json-schema "$schema" \
  --permission-mode dontAsk \
  --allowedTools "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)" "Bash(git blame *)" \
  "Bash(nix eval *)" "Bash(nix flake check *)" "Bash(nix build --no-link *)" \
  --add-dir /nix/store \
  --setting-sources user \
  --no-session-persistence)

post() {
  curl --silent --show-error --fail-with-body -X POST \
    -H "Authorization: token $FORGEJO_TOKEN" -H "Content-Type: application/json" \
    "$API/pulls/$PR/reviews" --data "$1"
}

# without structured output Claude stopped early (an error, a limit); say so on the pull request
if ! review=$(jq --exit-status '.structured_output' <<<"$answer"); then
  post "$(jq -n --arg sha "$HEAD_SHA" \
    '{commit_id: $sha, event: "COMMENT", body: "The review didn'"'"'t finish; see the review job'"'"'s log."}')"
  jq . <<<"$answer" >&2 || echo "$answer" >&2
  exit 1
fi

merge() {
  curl --silent --show-error --output /dev/stderr --write-out '%{http_code}' -X "$1" \
    -H "Authorization: token $MERGE_TOKEN" -H "Content-Type: application/json" \
    "$API/pulls/$PR/merge" "${@:2}"
}

# no findings: no review, the pull request merges once this job passes. MERGE_TOKEN is the owner's:
# a merge with the job's own token is forgejo-actions', whose push to stable starts no workflow
if jq --exit-status '.findings == []' <<<"$review" >/dev/null && [ "$CHECK" = success ]; then
  if [ -z "${MERGE_TOKEN:-}" ]; then
    echo "No findings; without MERGE_TOKEN the merge is the owner's." >&2
    exit 0
  fi
  # scheduled while this job runs (201; 409 when an earlier run did); a newer push's run cancels it
  status=$(merge POST --data "$(jq -n --arg sha "$HEAD_SHA" \
    '{Do: "merge", merge_when_checks_succeed: true, head_commit_id: $sha}')")
  case $status in
    200 | 201 | 409) exit 0 ;;
    *) echo "The merge failed: HTTP $status." >&2 && exit 1 ;;
  esac
fi

# findings take back a merge an earlier run scheduled; 404 when there is none
if [ -n "${MERGE_TOKEN:-}" ]; then
  case $(merge DELETE) in
    204 | 404) ;;
    *) echo "Cancelling the scheduled merge failed." >&2 && exit 1 ;;
  esac
fi

# a blocking finding requests changes; anything else is a comment
event=$(jq -r 'if any(.findings[]; .severity == "blocking") then "REQUEST_CHANGES" else "COMMENT" end' <<<"$review")

inline=$(jq --arg sha "$HEAD_SHA" --arg event "$event" '{
  commit_id: $sha,
  event: $event,
  body: ([.summary] + (.findings | map(select(.line == 0) | .body)) | join("\n\n")),
  comments: (.findings | map(select(.line > 0)
    | {path, body} + (if .side == "old" then {old_position: .line} else {new_position: .line} end)))
}' <<<"$review")

# Forgejo refuses the whole review when one line can't take a comment; then every finding goes
# into the review's text, each under its file and line
if ! post "$inline"; then
  post "$(jq --arg sha "$HEAD_SHA" --arg event "$event" '{
    commit_id: $sha,
    event: $event,
    body: ([.summary] + (.findings | map(
      if .line > 0 then "`\(.path):\(.line)`\n\n\(.body)" else .body end)) | join("\n\n---\n\n"))
  }' <<<"$review")"
fi

# a failed job is what blocks the merge into stable (a required check there)
if [ "$event" = REQUEST_CHANGES ]; then
  echo "The review requests changes." >&2
  exit 1
fi
