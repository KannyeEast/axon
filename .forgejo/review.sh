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
          "severity": { "enum": ["blocking", "should", "note"] },
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
# everything not listed instead of waiting for an approval nobody can give
answer=$(claude -p "$prompt" \
  --output-format json \
  --json-schema "$schema" \
  --permission-mode dontAsk \
  --allowedTools "Bash(git diff *)" "Bash(git log *)" "Bash(git show *)" "Bash(git blame *)" \
  "Bash(nix eval *)" "Bash(nix flake check *)" "Bash(nix build --no-link *)" \
  --add-dir /nix/store \
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

# a blocking finding requests changes; anything else is a comment, as merging is the owner's call
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
