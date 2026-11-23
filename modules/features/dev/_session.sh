# Read by modules/features/dev/sessions.nix: the `session` command.
#
# Lends the current folder to a server for a while: Mutagen keeps it in sync with
# ~/sessions/<name> there, where Claude runs in tmux (`sandbox claude --rc`), so the work goes on
# with this machine off and can be picked up from another one. The tmux session holds a `git`
# window (lazygit, then a shell, in the folder) and one window per chat.
#   session start [name]   from the project folder: link it, open the session there, attach
#   session attach [name]  back into the session; reopens it with a fresh chat if it ended
#   session chat [name]    one more chat in the running session (old ones: /resume in Claude)
#   session join <name>    on another machine: a copy in ~/sessions/<name>, linked to the same one
#   session leave [name]   end that copy (do this before `end` on the first machine)
#   session end [name]     wait for the last changes, unlink, stop Claude, remove the server's copy
#   session list
# The server is the first one this host may SSH to that lists dev; SESSION_SERVER picks another.

server=${SESSION_SERVER:-$DEFAULT_SERVER}
cmd=${1:-}
[ $# -gt 0 ] && shift

# Mutagen and tmux both want plain names
name=$(basename "${1:-$PWD}" | tr -c '[:alnum:]-\n' '-')
case $name in [[:alpha:]]*) ;; *) name="s-$name" ;; esac
remote="sessions/$name"

link() {
  if mutagen sync list "$name" >/dev/null 2>&1; then
    echo "session: $name is linked already; session attach $name" >&2
    exit 1
  fi
  # Mutagen makes the folder, not its parents
  ssh "$server" "mkdir -p \"\$HOME/sessions\""
  mutagen sync create --name "$name" --label session="$name" \
    "${IGNORED[@]/#/--ignore=}" \
    "$1" "$server:$remote"
  mutagen sync flush "$name"
}
# runs on the server, in the session's folder; windows start there too. "=" makes tmux
# match the name exactly; without it `axon` also finds `axon-docs`
chat="tmux new-window -t '=$name:' -n claude 'sandbox claude --rc'"
open="tmux has-session -t '=$name' 2>/dev/null || {
  tmux new-session -d -s '$name' -n git 'command -v lazygit >/dev/null && lazygit; exec \$SHELL' && $chat; }"
on_server() {
  exec ssh -t "$server" "cd \"\$HOME/$remote\" && { $1; } && exec tmux attach -t '=$name'"
}

case $cmd in
  start)
    link "$PWD"
    on_server "$open"
    ;;
  attach) on_server "$open" ;;
  chat) on_server "$chat" ;;
  join)
    [ $# -gt 0 ] || { echo "session join: which session? (session list)" >&2; exit 2; }
    mkdir -p "$HOME/$remote"
    link "$HOME/$remote"
    on_server "$open"
    ;;
  leave)
    mutagen sync flush "$name"
    mutagen sync terminate "$name"
    rm -rf "${HOME:?}/$remote"
    ;;
  end)
    mutagen sync flush "$name"
    mutagen sync terminate "$name"
    ssh "$server" "tmux kill-session -t '$name' 2>/dev/null; rm -rf \"\$HOME/$remote\""
    ;;
  list)
    mutagen sync list --label-selector session
    ssh "$server" "tmux ls 2>/dev/null || echo 'no sessions on $server'"
    ;;
  *)
    echo "usage: session start|attach|chat|join|leave|end|list [name]" >&2
    exit 2
    ;;
esac
