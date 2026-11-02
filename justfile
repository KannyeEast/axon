# Day-to-day commands. `just` lists them.
flake := justfile_directory()
host := shell("hostname -s")

# Forges: the first is origin; `just remotes` sets every one up as a push target.
forges := "codeberg=git@codeberg.org:KanyeSouth/axon.git " + \
  "github=git@github.com:KannyeEast/axon.git " + \
  "gitlab=git@gitlab.com:KanyeNorth/axon.git"

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

# Commit, asking for a conventional type and scope when no message is given
[group("git")]
commit MESSAGE="": stage
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  if git diff --cached --quiet; then
    echo "Nothing to commit."
    exit 0
  fi
  msg="{{MESSAGE}}"
  if [ -z "$msg" ]; then
    echo "Select commit type:"
    select type in feat fix docs refactor revert test chore skip; do
      case $type in
        skip) break ;;
        "") echo "Invalid selection"; exit 1 ;;
        *)
          read -rp "Enter scope: " scope
          read -rp "Enter description: " desc
          if [ -n "$scope" ]; then msg="$type($scope): $desc"; else msg="$type: $desc"; fi
          break
          ;;
      esac
    done
  fi
  [ -n "$msg" ] || { echo "Commit aborted."; exit 1; }
  git commit -m "$msg"

# Commit, then push to every forge
[group("git")]
push MESSAGE="": (commit MESSAGE)
  git -C {{flake}} push

# Pull, keeping local changes
[group("git")]
pull:
  git -C {{flake}} pull --rebase --autostash

# Publish main from dev: only the framework, never hosts/ or home/
[group("git")]
sync:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  git switch main 2>/dev/null || git switch -c main origin/main
  prev=$(git log -1 --format=%B --grep='^sync: (' | sed -n 's/^sync: (\([0-9a-f]\{7,40\}\))$/\1/p')
  git rm -rq --ignore-unmatch .
  git checkout dev -- modules/ flake.nix README.md AGENTS.md justfile install.sh 2>/dev/null || true
  if [ -n "$prev" ] && git cat-file -e "$prev^{commit}" 2>/dev/null; then range="$prev..dev"; else range="dev"; fi
  body=$(git log --no-merges --reverse --format='- %s' "$range")
  if git diff --cached --quiet; then
    echo "Nothing to sync."
  else
    git commit -m "sync: ($(git rev-parse dev))" -m "${body:-No individual commits.}"
    git push -u origin main --force
  fi
  git switch dev

# (Re)create the forge remotes; origin pushes to all of them
[group("git")]
remotes:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  read -ra pairs <<< "{{forges}}"
  for p in "${pairs[@]}" origin=x all=x; do git remote remove "${p%%=*}" 2>/dev/null || true; done
  for p in "${pairs[@]}"; do git remote add "${p%%=*}" "${p#*=}"; done
  git remote add origin "${pairs[0]#*=}"
  git remote set-url --delete --push origin '.*' 2>/dev/null || true
  for p in "${pairs[@]}"; do git remote set-url --add --push origin "${p#*=}"; done
  git fetch --all --prune
  for b in main dev; do
    git show-ref --verify -q "refs/heads/$b" && git branch --set-upstream-to="origin/$b" "$b" 2>/dev/null || true
  done
  git remote -v

# ── private helpers ────────
# Flakes only see files git knows about; make new ones visible without committing them
[private]
_stage:
  @git -C {{flake}} add --intent-to-add .
