# Day-to-day commands. `just` lists them.
flake := justfile_directory()
host := shell("hostname -s")

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
switch *ARGS: _stage
  nh os switch --ask {{flake}} {{ARGS}}

# Rebuild, activate on next boot
[group("system")]
boot *ARGS: _stage
  nh os boot --ask {{flake}} {{ARGS}}

# Build and show the changes
[group("system")]
build *ARGS: _stage
  nh os build {{flake}} {{ARGS}}

# Push and deploy to HOST; rolls back if it stops answering
[group("system")]
deploy HOST:
  #!/usr/bin/env bash
  set -euo pipefail
  cd {{flake}}
  if [ -n "$(git status --porcelain)" ]; then
    echo "just deploy: commit first, so {{HOST}}'s checkout matches what it runs" >&2
    exit 1
  fi
  git push
  ssh {{HOST}} git -C axon pull --ff-only
  nix run --inputs-from . nixpkgs#deploy-rs -- .#{{HOST}}

# Regenerate this machine's facter.json
[group("system")]
facter:
  sudo nix run nixpkgs#nixos-facter > {{flake}}/hosts/{{host}}/facter.json

# ── flake ────────
# Evaluate every host
[group("flake")]
check *ARGS: _stage
  nix flake check {{flake}} {{ARGS}}

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

# The host.toml / cluster.toml reference
[group("flake")]
docs:
  nix build {{flake}}#options --no-link --print-out-paths | xargs cat

# ── secrets ────────
# Edit a host's secrets (this one by default)
[group("secrets")]
secrets HOST=host:
  #!/usr/bin/env bash
  set -euo pipefail
  file=hosts/{{HOST}}/secrets.json
  cd {{flake}}
  if [ "{{HOST}}" = "{{host}}" ]; then exec sops "$file"; fi
  # only HOST can decrypt its secrets: sops runs there on this file, the encrypted result comes back
  trap 'rm -f "$file.new"; ssh {{HOST}} "git -C axon checkout -- $file"' EXIT
  ssh {{HOST}} "cat > axon/$file" <"$file"
  # 200: closed without a change
  ssh -t {{HOST}} "cd axon && sops $file" || [ $? -eq 200 ]
  ssh {{HOST}} "cat axon/$file" >"$file.new"
  [ -s "$file.new" ] && mv "$file.new" "$file"

# ── git ────────
# Push dev, open or update its pull request into stable
[group("git")]
pr:
  git -C {{flake}} push origin dev
  git -C {{flake}} push origin dev:refs/for/stable/dev -o title="dev to stable"

# ── private helpers ────────
# Flakes only see files git knows about
[private]
_stage:
  @git -C {{flake}} add --intent-to-add .
