#!/usr/bin/env bash
# tailnet.hujson through Tailscale's API: validate checks it, its tests included; apply makes it
# the tailnet's policy. An OAuth client with the policy_file scope in TS_OAUTH_CLIENT_ID and
# TS_OAUTH_CLIENT_SECRET.
set -euo pipefail

api=https://api.tailscale.com/api/v2
case "${1:-}" in
  validate) path=acl/validate ;;
  apply) path=acl ;;
  *)
    echo "usage: tailnet.sh validate|apply" >&2
    exit 2
    ;;
esac

token=$(curl -fsS -d "client_id=$TS_OAUTH_CLIENT_ID" -d "client_secret=$TS_OAUTH_CLIENT_SECRET" \
  "$api/oauth/token" | jq -r .access_token)
answer=$(curl -sS -w '\n%{http_code}' -H "Authorization: Bearer $token" \
  -H "Content-Type: application/hujson" --data-binary @tailnet.hujson "$api/tailnet/-/$path")
code=${answer##*$'\n'}
body=${answer%$'\n'*}

# a rejected policy or a failed test comes back as a message, with a 200 from validate
if [ "$code" != 200 ] || jq -e 'type == "object" and has("message")' <<<"$body" >/dev/null; then
  echo "$body" >&2
  exit 1
fi
echo "tailnet.hujson: $1 ok"
