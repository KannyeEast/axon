# Read by modules/features/dev/sandbox.nix: the `sandbox` command.
#
# `sandbox claude` runs Claude Code in the container (`sandbox claude --rc` reachable from
# claude.ai and the app); bare `sandbox` is a shell for trying untrusted code. Its home (Claude's
# login, shell history) persists in ~/.local/share/sandbox.

# the user's rootless daemon; DOCKER_HOST is only set where a shell started this
export DOCKER_HOST="${DOCKER_HOST:-unix://${XDG_RUNTIME_DIR:-/run/user/$UID}/docker.sock}"

# the image is built by Nix; load it the first time this version is used and drop the
# older ones, except one a running sandbox still holds (docker refuses those)
if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  "$IMAGE_STREAM" | docker load >/dev/null
  docker image ls sandbox --format '{{.Repository}}:{{.Tag}}' | grep -vxF "$IMAGE_NAME" \
    | xargs -r docker image rm >/dev/null 2>&1 || true
fi

state="${XDG_DATA_HOME:-$HOME/.local/share}/sandbox"
mkdir -p "$state"

# dotfiles are read-only in here, each file mounted by its real path (they're links
# into the checkout). ~/.config/claude/<path> is ~/.claude/<path>, except settings.json:
# it goes in through --settings, so it wins over ~/.claude/settings.json, which stays
# writable for what a session changes
config="${XDG_CONFIG_HOME:-$HOME/.config}"
opts=()
mirror() {
  local from=$1 to=$2 rel target
  [ -d "$from" ] || return 0
  while IFS= read -r rel; do
    target="$to/$rel"
    [ "$from/$rel" = "$config/claude/settings.json" ] && target=/home/sandbox/.config/claude/settings.json
    opts+=(--volume "$(readlink -f "$from/$rel"):$target:ro")
  done < <(find -L "$from" -type f -printf '%P\n')
}
mirror "$config/claude" /home/sandbox/.claude
# the status line Claude Code runs keeps its own place
mirror "$config/ccstatusline" /home/sandbox/.config/ccstatusline

# keys tools in here need (CONTEXT7_API_KEY=…), kept outside the dotfiles: they go public
secrets="$config/sandbox/secrets.env"
[ -f "$secrets" ] && opts+=(--env-file "$secrets")

args=("$@")
if [ "${1:-}" = claude ]; then
  args=(claude)
  [ -e "$config/claude/settings.json" ] \
    && args+=(--settings /home/sandbox/.config/claude/settings.json)
  # MCP servers of our own; the file is mirrored like the rest of ~/.config/claude. With
  # "=": the option takes several values and would swallow a subcommand (setup-token)
  [ -e "$config/claude/mcp.json" ] && args+=(--mcp-config=/home/sandbox/.claude/mcp.json)
  args+=("${@:2}")
fi

# the host's store, read-only, and its daemon: builds share the host's cache. The store
# is world-readable on the host anyway; secrets never enter it. Root in here is the user
# outside, so what it writes to $PWD is the user's and the nix daemon sees the user's uid.
exec docker run --rm -it \
  "${DNS[@]}" \
  --volume /nix/store:/nix/store:ro \
  --volume /nix/var/nix/daemon-socket:/nix/var/nix/daemon-socket \
  --volume "$PWD:$PWD" \
  --volume "$state:/home/sandbox" \
  "${opts[@]}" \
  --workdir "$PWD" \
  "$IMAGE_NAME" "${args[@]:-bash}"
