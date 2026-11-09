# Day-to-day commands. `just` lists them.
flake := justfile_directory()
host := shell("hostname -s")
# where origin lives, as https://host/owner/repo (from user@host:owner/repo.git and the like), and
# its API; empty before `just remotes`
forge := shell('git -C "$1" remote get-url origin 2>/dev/null | sed -E "s#^(ssh://)?[^@/]+@([^:/]+)[:/]#https://\\2/#; s#\\.git\$##" || true', flake)
api := replace_regex(forge, '^(https?://[^/]+)/(.*)$', '${1}/api/v1/repos/${2}')

alias s := switch
alias b := boot
alias c := check

# ── overview ────────
# This list
[group("default")]
default:
  @just --list

# ── system ────────
# Rebuild and activate
[group("system")]
switch *ARGS: pull _stage
  nh os switch --ask {{flake}} -H {{host}} {{ARGS}}

# Rebuild and activate on the next boot
[group("system")]
boot *ARGS: pull _stage
  nh os boot --ask {{flake}} -H {{host}} {{ARGS}}

# Build without activating, then show what would change
[group("system")]
build *ARGS: _stage
  nh os build {{flake}} -H {{host}} {{ARGS}}

# Push, then switch another host to it
[group("system")]
deploy HOST MESSAGE="": (push MESSAGE)
  ssh -t {{HOST}} just -f axon/justfile switch

# Regenerate this machine's hardware report after a hardware change
[group("system")]
facter:
  sudo nix run nixpkgs#nixos-facter > {{flake}}/hosts/{{host}}/facter.json

# Remove old generations and unused store paths
[group("system")]
clean:
  nh clean all --ask --keep-since 4d --keep 5

# ── flake ────────
# Evaluate every host: the bar for "done"
[group("flake")]
check *ARGS: _stage
  nix flake check {{flake}} {{ARGS}}

# Update all inputs, or the ones named
[group("flake")]
update *INPUTS: _stage
  nix flake update {{INPUTS}} --flake {{flake}}

# Format, then offer to remove dead code
[group("flake")]
fmt:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  nix fmt
  if nix run nixpkgs#deadnix -- --fail .; then
    echo "No dead code."
  else
    read -rp "Remove the above? [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]] && nix run nixpkgs#deadnix -- --edit .
  fi

# The host.toml / cluster.toml reference, generated from the schema
[group("flake")]
docs:
  nix build {{flake}}#options --no-link --print-out-paths | xargs cat

# ── secrets ────────
# Edit a host's secrets (this one by default)
[group("secrets")]
secrets HOST=host:
  sops {{flake}}/hosts/{{HOST}}/secrets.json

# ── git ────────
# Stage everything
[group("git")]
stage:
  git -C {{flake}} add .

# Commit everything with the given message; without one, stage and commit in lazygit, or type
# a message where lazygit isn't installed
[group("git")]
commit MESSAGE="":
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  msg="{{MESSAGE}}"
  if [ -z "$msg" ]; then
    command -v lazygit >/dev/null && exec lazygit
    read -rp "Commit message: " msg
    [ -n "$msg" ] || { echo "Commit aborted."; exit 1; }
  fi
  git add .
  if git diff --cached --quiet; then
    echo "Nothing to commit."
    exit 0
  fi
  git commit -m "$msg"

# Commit, then push to origin; the mirrors only get stable and main, from origin
[group("git")]
push MESSAGE="": (commit MESSAGE)
  git -C {{flake}} push

# Pull, keeping local changes
[group("git")]
pull:
  git -C {{flake}} pull --rebase --autostash

# Push dev, open its pull request into stable (or take the open one) and have Forgejo merge it
# once check and review pass; the merge publishes stable and main to the mirrors
[group("git")]
pr:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  token=${FORGEJO_TOKEN:-$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/forgejo/token" 2>/dev/null || true)}
  if [ -z "$token" ]; then
    echo "just pr: needs a Forgejo token (repository: read and write) in \$FORGEJO_TOKEN or ~/.config/forgejo/token" >&2
    exit 1
  fi
  git push origin dev
  git fetch --quiet origin
  if [ "$(git rev-list --count origin/stable..origin/dev)" -eq 0 ]; then
    echo "stable already has everything on dev."
    exit 0
  fi
  web="{{forge}}" api="{{api}}"
  call() { curl --silent --show-error -H "Authorization: token $token" -H "Content-Type: application/json" "$@"; }
  number=$(call --fail-with-body "$api/pulls?state=open&limit=50" \
    | jq '[.[] | select(.base.ref == "stable" and .head.ref == "dev")][0].number // empty')
  if [ -z "$number" ]; then
    number=$(call --fail-with-body -X POST "$api/pulls" --data '{"base": "stable", "head": "dev", "title": "dev → stable"}' | jq .number)
  fi
  # merges right away when the checks are already green; 409: a merge is already scheduled
  status=$(call -o /dev/null -w '%{http_code}' -X POST "$api/pulls/$number/merge" \
    --data '{"Do": "fast-forward-only", "merge_when_checks_succeed": true}')
  case "$status" in
    2*|409) echo "$web/pulls/$number merges into stable once check and review pass" ;;
    *) echo "just pr: scheduling the merge of $web/pulls/$number failed (HTTP $status)" >&2; exit 1 ;;
  esac

# The open findings of the latest review on the pull request into stable: summary, file:line, text
[group("git")]
findings:
  cd {{flake}} && FORGE="{{forge}}" API="{{api}}" bash .forgejo/findings.sh

# Publish main from stable by hand; CI does it after every merge into stable
[group("git")]
sync:
  cd {{flake}} && bash .forgejo/sync.sh

# (Re)create the remotes under [repo] in cluster.toml; origin is the one pulled from and pushed to
[group("git")]
remotes:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  # origin's name, then "<name> <url>" per remote
  mapfile -t lines < <(nix eval --raw --impure --expr '
    let
      repo = (builtins.fromTOML (builtins.readFile ./cluster.toml)).repo or { };
    in
    builtins.concatStringsSep "\n" (
      [ (repo.origin or "") ]
      ++ builtins.attrValues (builtins.mapAttrs (name: url: "${name} ${url}") (repo.remotes or { }))
    )')
  origin=${lines[0]:-}
  remotes=("${lines[@]:1}")
  if [ ${#remotes[@]} -eq 0 ]; then
    echo "cluster.toml: no [repo.remotes], nothing to set up."
    exit 0
  fi
  if [ -z "$origin" ]; then
    echo "cluster.toml: [repo] needs an origin, one of the names under [repo.remotes]." >&2
    exit 1
  fi
  for r in "${remotes[@]}" "origin x" "all x"; do git remote remove "${r%% *}" 2>/dev/null || true; done
  for r in "${remotes[@]}"; do git remote add "${r%% *}" "${r#* }"; done
  git remote add origin "$(git remote get-url "$origin")"
  git fetch --all --prune
  for b in main stable dev; do
    git show-ref --verify -q "refs/heads/$b" && git branch --set-upstream-to="origin/$b" "$b" 2>/dev/null || true
  done
  git remote -v

# ── private helpers ────────
# Flakes only see files git knows about; make new ones visible without committing them
[private]
_stage:
  @git -C {{flake}} add --intent-to-add .
