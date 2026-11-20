#!/usr/bin/env bash
#
# install.sh: put a machine into the repo and install it
#
#   ./install.sh        this machine, booted from the NixOS installer USB
#   ./install.sh -r     another machine over SSH, key login as root, through nixos-anywhere;
#                       a running Linux is switched into the installer in RAM first
#
# It asks a few questions, writes hosts/<name>/ (host.toml, facter.json, secrets.json), the
# machine's keys into .sops.yaml and its relations into cluster.toml, lets you add what the
# questions don't cover (the features' tables and secrets), checks that the config evaluates,
# commits, and only then wipes and installs. An existing hosts/<name> is reinstalled with its
# settings, and keeps its keys when they still open its secrets.json.

set -Eeuo pipefail

# ── script variables ────────
VERBOSE=false
REMOTE=false
# the question steps for what is known so far, and whether the current one showed a prompt
STEPS=()
ASKED=false

HOSTNAME=""
HOST_KEY=""
EXISTING=false
PRESERVE=false
REDO_DISK=false
CLASS=""
FEATURES=()
USERNAME=""
USEREMAIL=""
USER_KEY=""
QUIRKS=()
TIMEZONE=""
LOCALE=""
KEYBOARD=""
KEYBOARD_VARIANT=""
SYNC_ID=""
# where the config keeps Syncthing's keys (syncPlace), and where they were staged
SYNC_DIR=""
SYNC_ROOT=""
SYNC_DEVICE=""
SYNC_SUBVOL=""
SYNC_PATH=""

DISK=""
DISK_NAME=""
DISK_GIB=0
MIN_SYSTEM_GIB=30
SWAP=""
RESERVE=0
# data disks to wipe before the install
WIPE=()

# data disks: one entry per [disk.<label>]
DATA_LABELS=()
DATA_DEVICES=()
DATA_PROFILES=()
DATA_MOUNTS=()

# cluster.toml relations: members that log in here, members this host logs in to, [sync] folders
SSH_IN=()
SSH_OUT=()
SYNC_FOLDERS=()

HOST_AGE=""
USER_AGE=""

FLAKE=""
TEMP_DIR=""
DOTFILES_METHOD=""
DOTFILES=""
SSH_OPTS=()
TARGET=""
TARGET_MAC=""
TARGET_NET=""
REGISTRY=""

# ── theme ────────
FG="#c6c8d1"
MUTED="#6c7086"
CURSOR="#7aa2f7"
ACCENT="#9ece6a"
BASE="#1a1b26"

export GUM_INPUT_PROMPT="  "
export GUM_INPUT_WIDTH="60"
export GUM_INPUT_CURSOR_FOREGROUND="$CURSOR"
export GUM_INPUT_PROMPT_FOREGROUND="$FG"
export GUM_INPUT_HEADER_FOREGROUND="$FG"
export GUM_INPUT_PLACEHOLDER_FOREGROUND="$MUTED"

export GUM_CHOOSE_CURSOR="→ "
export GUM_CHOOSE_HEADER_FOREGROUND="$FG"
export GUM_CHOOSE_CURSOR_FOREGROUND="$CURSOR"
export GUM_CHOOSE_SELECTED_FOREGROUND="$ACCENT"

export GUM_FILTER_INDICATOR="→"
export GUM_FILTER_HEADER_FOREGROUND="$FG"
export GUM_FILTER_INDICATOR_FOREGROUND="$CURSOR"
export GUM_FILTER_MATCH_FOREGROUND="$ACCENT"
export GUM_FILTER_PLACEHOLDER_FOREGROUND="$MUTED"
export GUM_FILTER_PROMPT_FOREGROUND="$FG"

export GUM_CONFIRM_PROMPT_FOREGROUND="$FG"
export GUM_CONFIRM_SELECTED_BACKGROUND="$CURSOR"
export GUM_CONFIRM_SELECTED_FOREGROUND="$BASE"
export GUM_CONFIRM_UNSELECTED_FOREGROUND="$MUTED"

export GUM_SPIN_SPINNER_FOREGROUND="$CURSOR"

# ── logging/helpers ────────
logInfo() { gum log --level info "$*"; }
logWarn() { gum log --level warn "$*"; }
logError() { gum log --level error "$*"; }
logDebug() { gum log --level debug "$*"; }

die() { logError "$1"; exit "${2:-1}"; }

# wrap command in gum styling
run() {
  if [[ $VERBOSE == true ]]; then
    logDebug "\$ $*"
    "$@"
  else
    gum spin --title "$*" --show-error -- "$@"
  fi
}

nixx() { nix --extra-experimental-features "nix-command flakes" "$@"; }

sshInit() {
  SSH_OPTS=(
    -o ControlMaster=auto
    -o ControlPath="$TEMP_DIR/ssh-%C"
    -o ControlPersist=120
    -o ConnectTimeout=10
    -o UserKnownHostsFile="$TEMP_DIR/known_hosts"
    -o StrictHostKeyChecking=accept-new
  )
}

# decide where to execute command; local commands run as root, like remote ones
probe() {
  if [[ $REMOTE == true ]]; then
    ssh "${SSH_OPTS[@]}" "$TARGET" "$(printf '%q ' "$@")"
  else
    sudo "$@"
  fi
}

# the target runs the NixOS installer (USB or nixos-anywhere's kexec), not an installed system
isInstaller() {
  # the same test nixos-anywhere makes
  probe grep -Eq 'VARIANT_ID="?installer"?' /etc/os-release
}

# the keys of an install that hasn't finished yet; a rerun after a failure picks them up
keepDir() { printf '%s' "${XDG_CACHE_HOME:-$HOME/.cache}/axon-install/$HOSTNAME"; }

# a root-owned file of the target, copied here; no file when it can't be read
fetchRoot() { probe cat "$1" > "$2" 2>/dev/null || rm -f "$2"; }

# Syncthing's key pair, from a folder of the target into $TEMP_DIR/syncthing
fetchSyncKeys() {
  fetchRoot "$1/cert.pem" "$TEMP_DIR/syncthing/cert.pem"
  fetchRoot "$1/key.pem" "$TEMP_DIR/syncthing/key.pem"
}

# Where the evaluated config keeps Syncthing's keys: its config dir, the persistence root holding
# it (/persist, or the state volume when the host has one) and that root's filesystem.
syncPlace() {
  local json
  json="$(nixx eval --json "$FLAKE#nixosConfigurations.$HOSTNAME.config" --apply '
    c:
    let
      dir = c.services.syncthing.configDir;
      persistence = c.environment.persistence;
      root = builtins.head (
        builtins.filter (
          r: builtins.any (d: d.directory == dir) (builtins.getAttr r persistence).directories
        ) (builtins.attrNames persistence)
      );
      fs = builtins.getAttr root c.fileSystems;
    in
    {
      inherit dir root;
      inherit (fs) device;
      subvol = builtins.head (
        builtins.concatMap (
          o:
          let
            m = builtins.match "subvol=(.*)" o;
          in
          if m == null then [ ] else m
        ) fs.options
        ++ [ null ]
      );
    }' 2>/dev/null)" || return 1
  SYNC_DIR="$(jq -r .dir <<< "$json")"
  SYNC_ROOT="$(jq -r .root <<< "$json")"
  SYNC_DEVICE="$(jq -r .device <<< "$json")"
  SYNC_SUBVOL="$(jq -r '.subvol // empty' <<< "$json")"
}

# every IPv4 address the card with this MAC has on this machine's network. Each address of
# the /24 is pinged once so the neighbour table fills; a host that drops pings still answers ARP.
findByMac() {
  local mac="$1" base i
  base="${2%/*}"
  base="${base%.*}"
  (
    for (( i = 1; i < 255; i++ )); do ping -c1 -W1 "$base.$i" &>/dev/null & done
    wait
  ) || true
  ip -4 neigh show | awk -v m="$mac" 'tolower($0) ~ m && $NF != "FAILED" { print $1 }'
}

# ── traps ────────
trapError() {
  local code=$? cmd=$BASH_COMMAND line=${BASH_LINENO[0]} fn=${FUNCNAME[1]:-main}
  logError "'$cmd' failed (exit $code) at $fn():$line"
  exit "$code"
}
trap trapError ERR

cleanup() {
  if [[ -n ${TEMP_DIR:-} ]]; then
    if mountpoint -q "$TEMP_DIR/oldroot" 2>/dev/null; then
      sudo umount "$TEMP_DIR/oldroot" || true
    fi
    ssh -o ControlPath="$TEMP_DIR/ssh-%C" -O exit "$TARGET" &>/dev/null || true
    if [[ -d $TEMP_DIR ]]; then
      rm -rf "$TEMP_DIR"
    fi
  fi
  printf '\033[?25h' >&2
}
trap cleanup EXIT

# ── flags ────────
showFlags() {
  cat <<EOF
Usage: ./install.sh [OPTIONS]

Options:
  -r, --remote            Install another machine over SSH, through nixos-anywhere
  -v, --verbose           Show every command and its output
  -h, --help              This message
EOF
}

parseArgs() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -r|--remote) REMOTE=true; shift ;;
      -v|--verbose) VERBOSE=true; shift ;;
      -h|--help) showFlags; exit 0 ;;
      *) printf 'Unknown option: %s\n' "$1" >&2; showFlags; exit 1 ;;
    esac
  done
}

# ── shell packages ────────
# The repo's own nixpkgs, so the tools are the ones the systems are built with
PACKAGES=(gum git jq yq-go gawk mkpasswd openssh sops ssh-to-age syncthing)

shell() {
  if [[ -z ${INSTALLER_SHELL:-} ]]; then
    local flake
    flake=$(dirname -- "$(readlink -f -- "$0")")

    printf 'Fetching dependencies; this needs the network (Wi-Fi: connect with nmtui first) ...\n'
    # locale -a and the layout list read these instead of the host's
    LOCALE_ARCHIVE="$(nixx build --no-link --print-out-paths --inputs-from "$flake" nixpkgs#glibcLocales)/lib/locale/locale-archive"
    XKB_RULES="$(nixx build --no-link --print-out-paths --inputs-from "$flake" nixpkgs#xkeyboard_config)/share/X11/xkb/rules/base.lst"
    # NixOS's glibc reads the versioned name first, and the host sets it to its own few locales
    LOCALE_ARCHIVE_2_27="$LOCALE_ARCHIVE"
    export LOCALE_ARCHIVE LOCALE_ARCHIVE_2_27 XKB_RULES INSTALLER_SHELL=1

    exec nix --extra-experimental-features "nix-command flakes" shell --inputs-from "$flake" \
      "${PACKAGES[@]/#/nixpkgs#}" -c bash "$0" "$@"
  fi
}

# ── gum wrappers ────────
formHeader() {
  gum style --bold --foreground="$FG" \
    --border=rounded --border-foreground="$MUTED" \
    --padding="0 2" --margin="1 0" "$*"
}

# Esc on a prompt goes one step back (gather): the wrapper returns 1 and the step with it.
# Ctrl-C, gum's 130, stops the run. A check named last gets the value and says what's wrong.
# Each prompt sets ASKED, so gather can pass over a step that had nothing to ask.
back() {
  (( $1 != 130 )) || die "Cancelled" 130
  return 1
}

# a value that can't be empty; the third argument fills the field
formInput() {
  ASKED=true
  local __var="$1" label="$2" value="${3:-}" placeholder="${4:-${3:-$2}}" check="${5:-}"
  while :; do
    value=$(gum input --header="$label" --placeholder="$placeholder" --value="$value") || back $? || return 1
    if [[ -z $value ]]; then
      logWarn "$label: empty; type one"
    elif [[ -z $check ]] || "$check" "$value"; then
      break
    fi
  done
  printf -v "$__var" '%s' "$value"
  gum style --foreground="$MUTED" "$label: $value"
}

# empty takes the default, which the field shows; without one, empty is the answer
formInputOpt() {
  ASKED=true
  local __var="$1" label="$2" default="${3:-}" check="${4:-}" value
  while :; do
    value=$(gum input --header="$label" --placeholder="${default:-$label}") || back $? || return 1
    value="${value:-$default}"
    if [[ -z $value || -z $check ]] || "$check" "$value"; then
      break
    fi
  done
  printf -v "$__var" '%s' "$value"
  gum style --foreground="$MUTED" "$label: ${value:-skip}"
}

formPassword() {
  ASKED=true
  local __var="$1" label="$2" confirm="${3:-true}" minlen="${4:-8}" pw pw2
  while :; do
    pw=$(gum input --password --header="$label" --placeholder="$label") || back $? || return 1
    (( ${#pw} >= minlen )) || { logWarn "$label: at least $minlen characters"; continue; }
    [[ $confirm == true ]] || break
    pw2=$(gum input --password --header="Repeat $label" --placeholder="Repeat $label") || back $? || return 1
    [[ $pw == "$pw2" ]] && break
    logWarn "$label: the two don't match; type it again"
  done
  printf -v "$__var" '%s' "$pw"
}

formChoose() {
  ASKED=true
  local __var="$1" label="$2"; shift 2
  local selected
  selected=$(gum choose --header="$label" --selected="$1" --height=15 "$@") || back $? || return 1
  printf -v "$__var" '%s' "$selected"
  gum style --foreground="$MUTED" "$label: $selected"
}

# the third argument: the options that start selected, comma-separated
formMulti() {
  ASKED=true
  local __var="$1" label="$2" preselected="$3"; shift 3
  local selected
  selected=$(gum choose --no-limit --header="$label" --height=15 --selected="$preselected" "$@") || back $? || return 1
  local -n __ref="$__var"
  if [[ -n $selected ]]; then mapfile -t __ref <<< "$selected"; else __ref=(); fi
  gum style --foreground="$MUTED" "$label: ${__ref[*]:-none}"
}

# yes or no as a list, the answer in the variable: gum confirm ends the same on Esc and on no,
# so it couldn't go back
formYesNo() {
  ASKED=true
  local __var="$1" label="$2" default="${3:-no}" __reply
  __reply=$(gum choose --header="$label" --selected="$default" yes no) || back $? || return 1
  printf -v "$__var" '%s' "$__reply"
  gum style --foreground="$MUTED" "$label: $__reply"
}

# after the questions, with no step to go back to: Esc is no
formConfirm() {
  local reply
  formYesNo reply "$1" "${2:-no}" && [[ $reply == yes ]]
}

# a pick from a list, typed in when there is no list; the fourth argument fills the search field
formFilter() {
  ASKED=true
  local __var="$1" label="$2" options="$3" value="${4:-}" check="${5:-}" selected
  if [[ -z $options ]]; then
    formInput "$__var" "$label" "$value" "" "$check" || return 1
    return 0
  fi
  selected=$(gum filter --header="$label" --height=15 --value="$value" <<< "$options") || back $? || return 1
  printf -v "$__var" '%s' "$selected"
  gum style --foreground="$MUTED" "$label: $selected"
}

# the host name typed back, before anything is wiped
typedYes() {
  local reply
  reply=$(gum input --header="$1" --placeholder="type $HOSTNAME") || back $? || return 1
  [[ $reply == "$HOSTNAME" ]]
}

# the last stop before the install wipes
formTypeName() {
  typedYes "$1" || die "Stopped; hosts/$HOSTNAME is written and committed, nothing was wiped"
}

# ── checks for the prompts ────────
validHostname() { # RFC 1123
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && return 0
  logWarn "Hostname: lowercase letters, digits and hyphens, at most 63, no hyphen first or last"
  return 1
}

validUser() { # useradd's rule, as host.toml's user.name takes it
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root ]] && return 0
  logWarn "Username: lowercase letters, digits, hyphens and underscores, at most 32, starting with a letter or underscore; not root"
  return 1
}

validEmail() {
  [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && return 0
  logWarn "Email: name@domain.tld"
  return 1
}

validTimezone() {
  local dir
  for dir in /etc/zoneinfo /usr/share/zoneinfo; do
    [[ -d $dir ]] || continue
    [[ -f $dir/$1 ]] && return 0
    logWarn "Timezone: $1 isn't in $dir; e.g. UTC or Europe/Paris"
    return 1
  done
  return 0
}

validDir() {
  [[ -d ${1/#\~/$HOME} ]] && return 0
  logWarn "Folder: $1 doesn't exist here"
  return 1
}

validLabel() { # a data disk's name, its filesystem label
  if [[ ! $1 =~ ^[a-z][a-z0-9-]*$ || $1 == boot ]]; then
    logWarn "Name: lowercase letters, digits and hyphens, starting with a letter; not boot"
    return 1
  fi
  if printf '%s\n' "${DATA_LABELS[@]}" | grep -qx -- "$1"; then
    logWarn "Name: $1 is taken"
    return 1
  fi
}

validSubvolume() {
  [[ $1 =~ ^[a-z0-9_-]+$ ]] && return 0
  logWarn "Subvolume: lowercase letters, digits, hyphens and underscores"
  return 1
}

validMountpoint() {
  [[ $1 =~ ^/[^\"\\[:space:]]*$ ]] && return 0
  logWarn "Mount point: an absolute path without spaces or quotes"
  return 1
}

# the boot disk leaves the system what the 1 GiB ESP, swap and the reserve don't take
roomLeft() {
  local swap="$1" reserve="$2" left
  left=$(( DISK_GIB - 1 - swap - reserve ))
  (( left >= MIN_SYSTEM_GIB )) && return 0
  logWarn "That leaves ${left}GiB of the ${DISK_GIB}GiB disk for the system; it needs at least ${MIN_SYSTEM_GIB}GiB"
  return 1
}

validSwap() {
  [[ $1 =~ ^[0-9]+$ ]] || { logWarn "Swap: a whole number of GiB"; return 1; }
  roomLeft "$1" "$RESERVE"
}

validReserve() {
  [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 )) || { logWarn "Reserve: a whole number of GiB, 1 or more"; return 1; }
  roomLeft "$SWAP" "$1"
}

# ── toml ────────
tomlJson() { yq -p toml -o json '.' "$1"; }

# set KEY in [SECTION] to a raw TOML value, adding the key or the section if missing. A new key
# goes after the section's last one: blank and comment lines after it are held back until then.
tomlSet() {
  local file="$1" section="$2" key="$3" value="$4"
  awk -v s="[$section]" -v k="$key" -v v="$value" '
    function add() { if (insec && !done) { print k " = " v; done = 1 } }
    function flush() { for (i = 1; i <= held; i++) print hold[i]; held = 0 }
    /^\[/ { add(); flush(); insec = ($0 == s); print; next }
    insec && /^[ \t]*(#|$)/ { hold[++held] = $0; next }
    insec && index($0, k " ") == 1 && $0 ~ ("^" k "[ ]*=") { flush(); print k " = " v; done = 1; next }
    { flush(); print }
    END {
      add()
      flush()
      if (!done) { print ""; print s; print k " = " v }
    }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

tomlList() { # bash array -> TOML array of strings
  local out="" item
  for item in "$@"; do out+="\"$item\", "; done
  printf '[%s]' "${out%, }"
}

jsonList() { jq -nc '$ARGS.positional' --args "$@"; } # bash array -> JSON array of strings

# cluster.toml as JSON; {} while there is none
clusterJson() {
  if [[ -f $FLAKE/cluster.toml ]]; then tomlJson "$FLAKE/cluster.toml"; else echo '{}'; fi
}

# ── filter lists ────────
listNixosHardwareModules() {
  local rev ref="github:NixOS/nixos-hardware"
  rev="$(jq -r '.nodes["nixos-hardware"].locked.rev // empty' "$FLAKE/flake.lock" 2>/dev/null || true)"
  [[ -n $rev ]] && ref="$ref/$rev"

  local json="" err
  err="$(mktemp)"

  if ! json="$(timeout 120 nix --extra-experimental-features 'nix-command flakes' eval "$ref#nixosModules" --json --apply builtins.attrNames 2>"$err")"; then
    logWarn "Could not fetch nixos-hardware modules"
    logDebug "$(cat "$err")"
    rm -f "$err"
    return 1
  fi
  rm -f "$err"

  jq -r '.[]' <<< "$json" | sort
}

listSupportedTimezones() {
  local zones=""
  zones=$(timedatectl list-timezones 2>/dev/null || true)

  if [[ -z $zones ]]; then
    zones=$(find /usr/share/zoneinfo /etc/zoneinfo -type f -printf '%P\n' 2>/dev/null \
      | grep -v -E '^(posix|right|Etc)/' | sort -u || true)
  fi

  printf '%s\n' "$zones"
}

listSupportedLocales() {
  command -v locale &>/dev/null || return 1
  locale -a 2>/dev/null \
    | grep -iE '\.utf-?8$' \
    | sed -E 's/\.utf-?8$/.UTF-8/I' \
    | sort -u
}

listKeyboardLayouts() {
  [[ -r ${XKB_RULES:-} ]] || return 1
  awk '/^! layout/{f=1;next} /^!/{f=0} f&&NF{print $1}' "$XKB_RULES"
}

listKeyboardVariants() {
  printf '(none)\n'
  [[ -r ${XKB_RULES:-} ]] || return 0
  # Variant rows read "  nodeadkeys   de: German (no dead keys)"
  awk -v l="$1" '/^! variant/{f=1;next} /^!/{f=0} f&&$2==l":"{print $1}' "$XKB_RULES"
}

# the disks, without the installer's own stick (the disk under /iso, when it runs from one)
listDisks() {
  local stick
  # shellcheck disable=SC2016
  stick="$(probe sh -c 'src=$(findmnt -no SOURCE /iso) && lsblk -nrso NAME,TYPE "$src"' 2>/dev/null \
    | awk '$2 == "disk" { print $1; exit }')" || true
  probe lsblk -dno NAME,SIZE,MODEL -e 7,11 | awk -v stick="$stick" 'NF && $1 != stick'
}

# a disk's by-id path, which survives disks being renumbered
diskId() {
  local name="$1" byid
  byid="$(probe ls -l /dev/disk/by-id/ | awk -v d="$name" \
    '$NF ~ ("/" d "$") && $9 !~ /-part|^wwn-|^nvme-eui/ {print "/dev/disk/by-id/" $9; exit}' || true)"
  [[ -n $byid ]] || byid="$(probe ls -l /dev/disk/by-id/ | awk -v d="$name" \
    '$NF ~ ("/" d "$") && $9 !~ /-part/ {print "/dev/disk/by-id/" $9; exit}' || true)"
  printf '%s' "${byid:-/dev/$name}"
}

# ── information gathering ────────
# Each step asks its part and returns 1 when Esc goes back; gather runs them in order.
gatherTarget() {
  formHeader "Target"

  while :; do
    formInput TARGET "SSH destination (root)" "$TARGET" "root@192.168.1.50" || return 1
    [[ $TARGET == *@* ]] || TARGET="root@$TARGET"
    if [[ ${TARGET%%@*} != root ]]; then
      logWarn "Target: nixos-anywhere logs in as root; type root@<address>"
      continue
    fi

    # Key login only: after the switch into the installer a password no longer works
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" true; then
      break
    fi
    logWarn "Target: can't log in to $TARGET with a key. On the target, as root: add your key to"
    logWarn "/root/.ssh/authorized_keys (installer USB: passwd, then from here ssh-copy-id $TARGET)"
  done

  logInfo "Connected to $(probe hostname) running $(probe uname -sr)"

  # an installer asks DHCP again and may come back at another address; its card finds it
  local dev
  TARGET_MAC="" TARGET_NET=""
  dev="$(probe ip -o -4 route show default \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')" || true
  if [[ -n $dev ]]; then
    TARGET_MAC="$(probe cat "/sys/class/net/$dev/address")" || true
    TARGET_NET="$(probe ip -o -4 addr show dev "$dev" | awk '{ print $4; exit }')" || true
  fi
  [[ -n $TARGET_MAC ]] && logInfo "Network card $TARGET_MAC on $TARGET_NET"

  if isInstaller; then
    logInfo "It runs the NixOS installer"
  else
    logInfo "It runs an installed system; it is switched into the installer in RAM before the install"
  fi
}

# the host's name; an existing hosts/<name> is reinstalled with its settings and, where they still
# open its secrets.json, its keys
gatherIdentity() {
  formHeader "Identity"
  EXISTING=false
  local reinstall

  while :; do
    formInput HOSTNAME "Hostname" "$HOSTNAME" "nixos" validHostname || return 1
    # a folder without host.toml is a run that stopped before writing it: installed as new
    if [[ ! -f $FLAKE/hosts/$HOSTNAME/host.toml ]]; then
      # nothing of a host looked at before carries over
      PRESERVE=false
      SYNC_ID=""
      clearKeys
      return 0
    fi
    logInfo "hosts/$HOSTNAME already exists"
    formYesNo reinstall "Reinstall $HOSTNAME with its settings?" no || continue
    [[ $reinstall == yes ]] || continue
    if ! loadHost; then
      logWarn "Hostname: pick a different one"
      continue
    fi
    EXISTING=true
    preserveIdentity
    return 0
  done
}

# reuse an existing host
loadHost() {
  local json
  json="$(tomlJson "$FLAKE/hosts/$HOSTNAME/host.toml")" || { logError "hosts/$HOSTNAME/host.toml: doesn't parse (above)"; return 1; }

  CLASS="$(jq -r '.host.class // empty' <<< "$json")"
  mapfile -t FEATURES < <(jq -r '.host.features[]?' <<< "$json")
  USERNAME="$(jq -r '.user.name // empty' <<< "$json")"
  USEREMAIL="$(jq -r '.user.email // empty' <<< "$json")"
  mapfile -t QUIRKS < <(jq -r '.hardware.quirks[]?' <<< "$json")
  TIMEZONE="$(jq -r '.locale.timezone // "UTC"' <<< "$json")"
  LOCALE="$(jq -r '.locale.language // "en_US.UTF-8"' <<< "$json")"
  KEYBOARD="$(jq -r '.locale.keyboard // "us"' <<< "$json")"
  KEYBOARD_VARIANT="$(jq -r '.locale.variant // empty' <<< "$json")"
  DISK="$(jq -r '.disk.boot.devices[0] // empty' <<< "$json")"
  SWAP="$(jq -r '.disk.boot.swap // 8' <<< "$json")"
  RESERVE="$(jq -r '.disk.boot.reserve // 0' <<< "$json")"
  SYNC_ID="$(jq -r '.sync.id // empty' <<< "$json")"

  # only for the summary; host.toml keeps its tables as they are
  local key
  DATA_LABELS=() DATA_DEVICES=() DATA_PROFILES=() DATA_MOUNTS=()
  while IFS=$'\t' read -r key; do
    DATA_LABELS+=("$key")
    DATA_DEVICES+=("$(jq -r --arg k "$key" '.disk[$k].devices | join(" ")' <<< "$json")")
    DATA_PROFILES+=("$(jq -r --arg k "$key" '.disk[$k].profile // "single"' <<< "$json")")
    DATA_MOUNTS+=("$(jq -r --arg k "$key" '.disk[$k].mounts | to_entries | map("\(.key) = \"\(.value)\"") | "{ " + join(", ") + " }"' <<< "$json")")
  done < <(jq -r '.disk // {} | keys[] | select(. != "boot")' <<< "$json")

  if [[ -z $USERNAME || -z $CLASS ]]; then
    logError "hosts/$HOSTNAME/host.toml: no user.name or host.class"
    return 1
  fi

  logInfo "Reusing hosts/$HOSTNAME"
  return 0
}

# class and features, as the flake declares them
gatherRole() {
  formHeader "Role"
  FEATURES=()

  local -a classes rows picked
  local row name

  mapfile -t classes < <(jq -r '.classes | keys[]' <<< "$REGISTRY")
  formChoose CLASS "Class" "${classes[@]}" || return 1
  # only desktops ask for reserved space; a value from an earlier pass or a loaded host stays out
  [[ $CLASS == desktop ]] || RESERVE=0

  mapfile -t rows < <(jq -r --arg c "$CLASS" \
    '.features | to_entries[] | select(.value.classes | index($c)) | "\(.key)  \(.value.description)"' <<< "$REGISTRY")
  (( ${#rows[@]} > 0 )) || return 0

  formMulti picked "Features" "" "${rows[@]}" || return 1
  for row in "${picked[@]}"; do
    FEATURES+=("${row%%  *}")
  done

  # a feature can need another
  local added=true req
  while [[ $added == true ]]; do
    added=false
    for name in "${FEATURES[@]}"; do
      while IFS= read -r req; do
        [[ -n $req ]] || continue
        if ! printf '%s\n' "${FEATURES[@]}" | grep -qx "$req"; then
          FEATURES+=("$req")
          logInfo "Added $req, which $name needs"
          added=true
        fi
      done < <(jq -r --arg f "$name" '.features[$f].requires[]?' <<< "$REGISTRY")
    done
  done
}

# key files of an earlier pass; ssh-keygen would stop at an existing one, and a kept one would
# be taken for this host's
clearKeys() {
  rm -rf "$TEMP_DIR"/ssh_host_ed25519_key "$TEMP_DIR"/ssh_host_ed25519_key.pub \
    "$TEMP_DIR"/id_ed25519 "$TEMP_DIR"/id_ed25519.pub "$TEMP_DIR/syncthing"
}

# whether the host key in $TEMP_DIR opens secrets.json, with no other key sops would also try
opensSecrets() {
  chmod 600 "$TEMP_DIR/ssh_host_ed25519_key"
  env -u SOPS_AGE_KEY_FILE -u SOPS_AGE_KEY_CMD \
    -u SOPS_AGE_SSH_PRIVATE_KEY_FILE -u SOPS_AGE_SSH_PRIVATE_KEY_CMD \
    HOME="$TEMP_DIR" XDG_CONFIG_HOME="$TEMP_DIR" \
    SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$TEMP_DIR/ssh_host_ed25519_key" 2>/dev/null)" \
    sops --decrypt "$FLAKE/hosts/$HOSTNAME/secrets.json" &>/dev/null
}

# Keys of an existing host: those of an unfinished run, else the old system's. They are kept only
# when they open its secrets.json; otherwise the host starts over with new ones.
preserveIdentity() {
  formHeader "Keys"
  PRESERVE=false
  clearKeys

  if [[ ! -f $FLAKE/hosts/$HOSTNAME/secrets.json ]]; then
    logWarn "hosts/$HOSTNAME has no secrets.json, keys are regenerated"
    return 0
  fi

  if [[ -s $(keepDir)/ssh_host_ed25519_key ]]; then
    cp "$(keepDir)/ssh_host_ed25519_key" "$TEMP_DIR/"
    if [[ -d $(keepDir)/syncthing ]]; then cp -r "$(keepDir)/syncthing" "$TEMP_DIR/"; fi
    if opensSecrets; then
      PRESERVE=true
      logInfo "Kept the keys of an unfinished install"
      return 0
    fi
    logWarn "The keys of an unfinished install don't open secrets.json; looking on the old system"
    clearKeys
  fi

  fetchOldKeys
  if [[ ! -s $TEMP_DIR/ssh_host_ed25519_key ]]; then
    clearKeys
    return 0
  fi
  if ! opensSecrets; then
    logWarn "The old system's host key doesn't open secrets.json, keys are regenerated"
    clearKeys
    return 0
  fi
  PRESERVE=true
  logInfo "Recovered the host key"
}

# the old system's host key and Syncthing keys, into $TEMP_DIR; a warning says why when there are none
fetchOldKeys() {
  local key="$TEMP_DIR/ssh_host_ed25519_key" part mnt="$TEMP_DIR/oldroot" syncing=false

  mkdir -p "$TEMP_DIR/syncthing"

  if printf '%s\n' "${FEATURES[@]}" | grep -qx sync; then
    if syncPlace; then
      syncing=true
    else
      logWarn "hosts/$HOSTNAME doesn't evaluate, so Syncthing's keys can't be found; they are regenerated"
    fi
  fi

  if [[ $REMOTE == true ]]; then
    # the old system is still running: read its keys directly
    if isInstaller; then
      logWarn "The target already runs the installer; the old keys can't be read, they are regenerated"
      return 0
    fi
    fetchRoot /persist/etc/ssh/ssh_host_ed25519_key "$key"
    if [[ $syncing == true ]]; then
      # the running system has them at their own path, wherever it persists them
      fetchSyncKeys "$SYNC_DIR"
    fi
  else
    mkdir -p "$mnt"
    # on the state volume: mounted by itself, as the config mounts it
    if [[ $syncing == true && $SYNC_ROOT != /persist ]]; then
      if sudo mount -o "ro${SYNC_SUBVOL:+,subvol=$SYNC_SUBVOL}" "$SYNC_DEVICE" "$mnt" 2>/dev/null; then
        fetchSyncKeys "$mnt$SYNC_DIR"
        sudo umount "$mnt"
      else
        logWarn "Could not mount $SYNC_DEVICE ($SYNC_ROOT), Syncthing's keys are regenerated"
      fi
    fi

    if [[ -z $DISK || ! -e $DISK ]]; then
      logWarn "Boot disk $DISK not found, keys are regenerated"
      return 0
    fi
    part="$(lsblk -lnpo PATH,FSTYPE "$DISK" | awk '$2 == "btrfs" { print $1; exit }')"
    if [[ -z $part ]]; then
      logWarn "No btrfs partition on $DISK, keys are regenerated"
      return 0
    fi
    if ! sudo mount -o subvol=/persist,ro "$part" "$mnt" 2>/dev/null; then
      logWarn "Could not mount $part, keys are regenerated"
      return 0
    fi
    fetchRoot "$mnt/etc/ssh/ssh_host_ed25519_key" "$key"
    if [[ $syncing == true && $SYNC_ROOT == /persist ]]; then
      fetchSyncKeys "$mnt$SYNC_DIR"
    fi
    sudo umount "$mnt"
  fi

  [[ -s $key ]] || logWarn "No host key on the old system, keys are regenerated"
}

# a layout change is the only reason to touch the disk settings of a host
gatherRedoDisk() {
  local redo
  formYesNo redo "Redo the boot disk layout?" "$([[ $REDO_DISK == true ]] && echo yes || echo no)" || return 1
  if [[ $redo == yes ]]; then
    REDO_DISK=true
  else
    REDO_DISK=false
    # host.toml's disk, swap and reserve again, should a visit to the disk steps have changed them
    loadHost >/dev/null
  fi
}

gatherUser() {
  formHeader "User"
  formInput USERNAME "Username" "${USERNAME:-$(whoami)}" "login name" validUser || return 1
  formInput USEREMAIL "Email (git identity, certificate contact)" "$USEREMAIL" "" validEmail || return 1
}

gatherLocale() {
  formHeader "Locale"
  # UTC is host.toml's default
  formFilter TIMEZONE "Timezone" "$(listSupportedTimezones)" "${TIMEZONE:-UTC}" validTimezone || return 1
  formFilter LOCALE "Language" "$(listSupportedLocales)" || return 1
  formFilter KEYBOARD "Keyboard layout" "$(listKeyboardLayouts)" || return 1
  formFilter KEYBOARD_VARIANT "Layout variant" "$(listKeyboardVariants "$KEYBOARD")" || return 1
  if [[ $KEYBOARD_VARIANT == "(none)" ]]; then
    KEYBOARD_VARIANT=""
  fi
}

# hardware: facter detects the rest
gatherHardware() {
  formHeader "Hardware"
  QUIRKS=()

  local fix models selection=""
  logInfo "CPU, GPU, firmware and drivers come from the hardware report"
  formYesNo fix "Add a model-specific fix from nixos-hardware?" no || return 1
  [[ $fix == yes ]] || return 0

  models="$(listNixosHardwareModules || true)"
  if [[ -n $models ]]; then
    formFilter selection "Search for your model" "$models" || return 1
  else
    logInfo "https://github.com/NixOS/nixos-hardware"
    formInputOpt selection "Module name" || return 1
  fi
  if [[ -n $selection ]]; then
    QUIRKS+=("$selection")
  fi
}

gatherDisk() {
  formHeader "Boot disk"

  local name disks size
  disks="$(listDisks)"
  [[ -n $disks ]] || die "Boot disk: no disks found on ${TARGET:-this machine}"
  logWarn "The selected disk will be wiped"
  formFilter name "Choose disk" "$disks" || return 1
  DISK_NAME="$(awk '{print $1}' <<< "$name")"
  DISK="$(diskId "$DISK_NAME")"
  size="$(probe lsblk -bdno SIZE "$DISK" | head -n1)" || true
  DISK_GIB=$(( ${size:-0} / 1073741824 ))
  logInfo "Disk: $DISK, ${DISK_GIB}GiB"
}

# data disks: each [disk.<label>] is one btrfs filesystem, on one disk or an array
gatherData() {
  formHeader "Data disks"
  DATA_LABELS=()
  DATA_DEVICES=()
  DATA_PROFILES=()
  DATA_MOUNTS=()

  local -a used=("$DISK_NAME") free picked devices profiles
  local add fsLabel profile mounts subvol mountpoint row another

  while :; do
    mapfile -t free < <(listDisks | awk -v used=" ${used[*]} " 'index(used, " " $1 " ") == 0')
    (( ${#free[@]} > 0 )) || break
    formYesNo add "Add a data disk?" no || return 1
    [[ $add == yes ]] || break

    formInput fsLabel "Name (the filesystem label)" "" "bulk" validLabel || return 1

    formMulti picked "Disks (space to select)" "" "${free[@]}" || return 1
    if (( ${#picked[@]} == 0 )); then
      logWarn "Data disks: none selected; $fsLabel is skipped"
      continue
    fi

    devices=()
    for row in "${picked[@]}"; do
      row="${row%% *}"
      used+=("$row")
      devices+=("$(diskId "$row")")
    done

    # the profiles the device count allows (the framework's minimums), mirrored first once there are two
    mapfile -t profiles < <(jq -r --argjson n "${#devices[@]}" '
      .profiles | to_entries | map(select(.value <= $n)) | sort_by(.value, .key)
      | (map(select(.key == "raid1")) + map(select(.key != "raid1")))[] | .key' <<< "$REGISTRY")
    if (( ${#profiles[@]} > 1 )); then
      formChoose profile "Profile" "${profiles[@]}" || return 1
    else
      profile="${profiles[0]}"
    fi

    mounts=""
    subvol="$fsLabel"
    while :; do
      formInputOpt subvol "Subvolume" "$subvol" validSubvolume || return 1
      [[ -n $subvol ]] || continue
      formInputOpt mountpoint "Mount $subvol at" "/server/$subvol" validMountpoint || return 1
      mounts+="$subvol = \"$mountpoint\", "
      formYesNo another "Another subvolume on $fsLabel?" no || return 1
      [[ $another == yes ]] || break
      subvol=""
    done

    DATA_LABELS+=("$fsLabel")
    DATA_DEVICES+=("${devices[*]}")
    DATA_PROFILES+=("$profile")
    DATA_MOUNTS+=("{ ${mounts%, } }")
    logInfo "disk.$fsLabel: ${#devices[@]} disk(s), $profile"
  done
}

gatherSwap() {
  formHeader "Swap"

  local ram swapDefault hibernate=no
  ram=$(( ( $(probe cat /proc/meminfo | awk '/MemTotal/{print $2}') + 524288 ) / 1048576 ))
  logInfo "Detected ${ram}GiB of RAM"
  if [[ $CLASS == desktop ]] && probe sh -c 'ls -d /sys/class/power_supply/BAT*' &>/dev/null; then
    logInfo "It has a battery"
    hibernate=yes
  fi

  swapDefault=8
  if [[ $CLASS == desktop ]]; then
    formYesNo hibernate "Enable hibernation?" "$hibernate" || return 1
    if [[ $hibernate == yes ]]; then swapDefault=$(( ram + 2 )); else swapDefault=0; fi
  fi

  formInputOpt SWAP "Swap size in GiB, 0 for none" "$swapDefault" validSwap || return 1
}

# room for another OS
gatherLayout() {
  formHeader "Layout"
  RESERVE=0

  local reserve
  formYesNo reserve "Reserve space for another OS?" no || return 1
  [[ $reserve == yes ]] || return 0
  formInputOpt RESERVE "Space to leave unallocated, in GiB" "$(( DISK_GIB / 2 ))" validReserve || return 1
}

gatherDotfiles() {
  formHeader "Dotfiles (optional)"
  DOTFILES=""

  local copy
  formYesNo copy "Copy this host's dotfiles from a source?" no || return 1
  [[ $copy == yes ]] || return 0

  formChoose DOTFILES_METHOD "Method" "path" "git clone" || return 1
  if [[ $DOTFILES_METHOD == "path" ]]; then
    formInput DOTFILES "Folder with the dotfiles" "" "/path/to/dotfiles" validDir || return 1
    DOTFILES="${DOTFILES/#\~/$HOME}"
  else
    formInput DOTFILES "git repo to clone" "" "enter link" || return 1
  fi
}

# cluster.toml's relations, [ssh] and [sync]: who logs in to this host, where it logs in, which
# folders it shares. Kept as they are unless changed here.
gatherCluster() {
  local json here d pre change leave
  local -a hosts=() logins folders=()
  json="$(clusterJson)"

  for d in "$FLAKE"/hosts/*/host.toml; do
    d="${d%/host.toml}"
    d="${d##*/}"
    if [[ -f $FLAKE/hosts/$d/host.toml && $d != _* && $d != "$HOSTNAME" ]]; then
      hosts+=("$d")
    fi
  done
  # an [external] member logs in with its key, but nothing logs in to it
  mapfile -t logins < <(printf '%s\n' "${hosts[@]}" | awk NF
    jq -r '.external // {} | to_entries[] | select(.value.key != null) | .key' <<< "$json")
  if printf '%s\n' "${FEATURES[@]}" | grep -qx sync; then
    mapfile -t folders < <(jq -r '.sync // {} | keys[]' <<< "$json")
  fi

  mapfile -t SSH_IN < <(jq -r --arg h "$HOSTNAME" '.ssh // {} | to_entries[] | select(any(.value[]; . == $h)) | .key' <<< "$json")
  mapfile -t SSH_OUT < <(jq -r --arg h "$HOSTNAME" '.ssh[$h] // [] | .[]' <<< "$json")
  mapfile -t SYNC_FOLDERS < <(jq -r --arg h "$HOSTNAME" '.sync // {} | to_entries[] | select(any(.value[]; . == $h)) | .key' <<< "$json")

  (( ${#logins[@]} + ${#folders[@]} > 0 )) || return 0
  formHeader "Cluster"

  if (( ${#SSH_IN[@]} + ${#SSH_OUT[@]} + ${#SYNC_FOLDERS[@]} > 0 )); then
    logInfo "cluster.toml has: ${SSH_IN[*]:-nobody} may log in here; $HOSTNAME may log in to ${SSH_OUT[*]:-none}; it syncs ${SYNC_FOLDERS[*]:-nothing}"
    formYesNo change "Change these relations?" no || return 1
    [[ $change == yes ]] || return 0
  fi

  if (( ${#logins[@]} > 0 )); then
    pre="$(IFS=,; echo "${SSH_IN[*]}")"
    # a server is managed over SSH: the machine installing it is the likely one
    here="$(uname -n)"
    here="${here%%.*}"
    if [[ $CLASS == server && -z $pre && $REMOTE == true ]] && printf '%s\n' "${logins[@]}" | grep -qx "$here"; then
      pre="$here"
    fi
    while :; do
      formMulti SSH_IN "May log in to $HOSTNAME with their key (space to select)" "$pre" "${logins[@]}" || return 1
      [[ $CLASS != server || ${#SSH_IN[@]} -gt 0 ]] && break
      logWarn "Cluster: with no member's key let in, $HOSTNAME takes only $USERNAME's password over SSH"
      formYesNo leave "Leave it so?" no || continue
      [[ $leave == yes ]] && break
    done
  fi

  if (( ${#hosts[@]} > 0 )); then
    formMulti SSH_OUT "$HOSTNAME may log in to (space to select)" "$(IFS=,; echo "${SSH_OUT[*]}")" "${hosts[@]}" || return 1
  fi

  if (( ${#folders[@]} > 0 )); then
    formMulti SYNC_FOLDERS "Folders $HOSTNAME keeps in sync (space to select)" \
      "$(IFS=,; echo "${SYNC_FOLDERS[*]}")" "${folders[@]}" || return 1
  fi
}

gatherSummary() {
  formHeader "Review Configuration"

  local i devices
  row() { printf '    %-14s %s\n' "$1" "$2"; }

  {
    if [[ $REMOTE == true ]]; then
      row Target "$TARGET"
      echo
    fi

    row Hostname "$HOSTNAME"
    row Class "$CLASS"
    row Features "${FEATURES[*]:-none}"
    row User "$USERNAME <$USEREMAIL>"
    row Quirks "${QUIRKS[*]:-none}"
    row Timezone "$TIMEZONE"
    row Language "$LOCALE"
    row Keyboard "$KEYBOARD${KEYBOARD_VARIANT:+ / $KEYBOARD_VARIANT}"
    row Disk "$DISK"
    row Swap "${SWAP}GiB"
    for i in "${!DATA_LABELS[@]}"; do
      read -ra devices <<< "${DATA_DEVICES[$i]}"
      row "disk.${DATA_LABELS[$i]}" "${DATA_PROFILES[$i]}, ${#devices[@]} disk(s), ${DATA_MOUNTS[$i]}"
    done
    if [[ $CLASS == "desktop" ]]; then
      row Reserved "$( (( RESERVE > 0 )) && echo "${RESERVE}GiB" || echo none)"
    fi
    row "SSH from" "${SSH_IN[*]:-none}"
    row "SSH to" "${SSH_OUT[*]:-none}"
    row Sync "${SYNC_FOLDERS[*]:-none}"
    if [[ $EXISTING == true ]]; then
      row Keys "$([[ $PRESERVE == true ]] && echo kept || echo "regenerated (secrets.json starts over)")"
    else
      row Dotfiles "${DOTFILES:-skip}"
    fi
  } | gum style --border="rounded" --padding="1 2" --margin="1 0"
}

# the steps for what is known so far: whether the host exists, its class, a redone disk layout
gatherSteps() {
  STEPS=()
  if [[ $REMOTE == true ]]; then
    STEPS+=(gatherTarget)
  fi
  STEPS+=(gatherIdentity)
  if [[ $EXISTING == true ]]; then
    STEPS+=(gatherRedoDisk)
    if [[ $REDO_DISK == true ]]; then
      STEPS+=(gatherDisk gatherSwap)
      if [[ $CLASS == desktop ]]; then
        STEPS+=(gatherLayout)
      fi
    fi
  else
    STEPS+=(gatherRole gatherUser gatherLocale gatherHardware gatherDisk gatherSwap)
    if [[ $CLASS == desktop ]]; then
      STEPS+=(gatherLayout)
    fi
    STEPS+=(gatherDotfiles gatherData)
  fi
  STEPS+=(gatherCluster)
}

# The steps one after another; Esc goes one back, and on the first one offers to quit. "No" at the
# summary starts over, with the answers given as defaults where a prompt takes one.
gather() {
  local i=0 correct forward=true
  clearKeys
  while :; do
    gatherSteps
    if (( i < ${#STEPS[@]} )); then
      ASKED=false
      if "${STEPS[i]}"; then
        # a step that asked nothing is passed over, going back too
        if [[ $forward == true || $ASKED == true ]] || (( i == 0 )); then
          forward=true
          i=$(( i + 1 ))
        else
          i=$(( i - 1 ))
        fi
      elif (( i > 0 )); then
        forward=false
        i=$(( i - 1 ))
      elif formConfirm "Quit? Nothing is written yet" no; then
        exit 0
      fi
      continue
    fi

    gatherSummary
    if ! formYesNo correct "Is this correct?" yes; then
      forward=false
      i=$(( i - 1 ))
      continue
    fi
    [[ $correct == yes ]] && break
    logWarn "Redoing..."
    clearKeys
    forward=true
    i=0
  done
}

# ── generate keys ────────
generate() {
  formHeader "Generating keys"

  # host keys
  if [[ $PRESERVE == true ]]; then
    # ssh-keygen -y prints no comment, so it is put back to keep host.toml stable
    printf '%s root@%s\n' "$(ssh-keygen -y -f "$TEMP_DIR/ssh_host_ed25519_key")" "$HOSTNAME" \
      > "$TEMP_DIR/ssh_host_ed25519_key.pub"
  else
    run ssh-keygen -q -t ed25519 -N "" -C "root@$HOSTNAME" -f "$TEMP_DIR/ssh_host_ed25519_key"
  fi

  HOST_AGE="$(ssh-to-age < "$TEMP_DIR/ssh_host_ed25519_key.pub")"
  HOST_KEY="$(< "$TEMP_DIR/ssh_host_ed25519_key.pub")"

  logInfo "Host fingerprint: $(ssh-keygen -lf "$TEMP_DIR/ssh_host_ed25519_key.pub")"

  # user keys
  if [[ $PRESERVE == true ]]; then
    # the user key is itself a secret, so the host key is enough to recover it
    SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$TEMP_DIR/ssh_host_ed25519_key")"
    export SOPS_AGE_KEY

    sops --decrypt "$FLAKE/hosts/$HOSTNAME/secrets.json" \
      | jq -je '.user["private-key"]' > "$TEMP_DIR/id_ed25519"
    chmod 600 "$TEMP_DIR/id_ed25519"

    printf '%s %s@%s\n' "$(ssh-keygen -y -f "$TEMP_DIR/id_ed25519")" "$USERNAME" "$HOSTNAME" \
      > "$TEMP_DIR/id_ed25519.pub"
  else
    run ssh-keygen -q -t ed25519 -N "" -C "$USERNAME@$HOSTNAME" -f "$TEMP_DIR/id_ed25519"
  fi

  USER_AGE="$(ssh-to-age < "$TEMP_DIR/id_ed25519.pub")"
  USER_KEY="$(< "$TEMP_DIR/id_ed25519.pub")"

  logInfo "User fingerprint: $(ssh-keygen -lf "$TEMP_DIR/id_ed25519.pub")"

  # the new user key opens secrets.json from here on (editing, the feature secrets)
  SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$TEMP_DIR/id_ed25519")"
  export SOPS_AGE_KEY

  # syncthing: the device id is its certificate's
  if printf '%s\n' "${FEATURES[@]}" | grep -qx sync; then
    local sync="$TEMP_DIR/syncthing"
    mkdir -p "$sync"
    if [[ -s $sync/cert.pem && -s $sync/key.pem ]]; then
      # the key decides the id; host.toml may still carry one from an earlier attempt
      SYNC_ID="$(syncthing device-id --home "$sync")"
      [[ -n $SYNC_ID ]] || die "Keys: can't read the Syncthing id from the kept key; rerun to start over with new keys"
      logInfo "Kept the Syncthing id: $SYNC_ID"
    else
      rm -f "$sync"/*
      SYNC_ID="$(syncthing generate --home "$sync" 2>&1 | grep -oE '[A-Z0-9]{7}(-[A-Z0-9]{7}){7}' | head -n1)"
      rm -f "$sync/config.xml"
      [[ -n $SYNC_ID ]] || die "Keys: syncthing generate gave no device id"
      logInfo "Syncthing id: $SYNC_ID"
    fi
  fi

  # secrets.json is encrypted to these from now on: kept until the install succeeds, so a
  # failed run doesn't leave a secrets.json nothing can open
  rm -rf "$(keepDir)"
  install -d -m 700 "$(keepDir)"
  cp "$TEMP_DIR"/ssh_host_ed25519_key "$TEMP_DIR"/ssh_host_ed25519_key.pub "$(keepDir)/"
  [[ -d $TEMP_DIR/syncthing ]] && cp -r "$TEMP_DIR/syncthing" "$(keepDir)/"
  return 0
}

# ── write .sops.yaml ────────
writeSopsYaml() {
  [[ -f .sops.yaml ]] || echo "creation_rules: []" > .sops.yaml

  # The machine's two keys may decrypt its secrets; nothing else. Each key is listed once
  # under keys, named <user>_<host> and <host>, and the rule refers to them by name.
  # This host's rule goes first, then its keys, so no alias points at a removed name.
  RULE="hosts/$HOSTNAME/secrets\\.json\$" HOST="$HOSTNAME" USERK="${USERNAME}_${HOSTNAME}" \
    USER_AGE="$USER_AGE" HOST_AGE="$HOST_AGE" yq -i '
    .creation_rules = [(.creation_rules // [])[] | select(.path_regex != strenv(RULE))]
    | .keys = [(.keys // [])[] | select(anchor != strenv(HOST) and anchor != strenv(USERK))]
    | .keys += [strenv(USER_AGE), strenv(HOST_AGE)]
    | .keys[-2] anchor = strenv(USERK)
    | .keys[-1] anchor = strenv(HOST)
    | .creation_rules += [{"path_regex": strenv(RULE), "key_groups": [{"age": ["", ""]}]}]
    | .creation_rules[-1].key_groups[0].age[0] alias = strenv(USERK)
    | .creation_rules[-1].key_groups[0].age[1] alias = strenv(HOST)
    | . = {"keys": .keys, "creation_rules": .creation_rules}
  ' .sops.yaml

  git -C "$FLAKE" add --intent-to-add .sops.yaml
  logInfo "Added ${USERNAME}_${HOSTNAME} and $HOSTNAME to .sops.yaml"
}

# ── write secrets.json ────────
# one secret into secrets.json, a/b for {"a": {"b": …}}; the value comes on stdin, off the command line
setSecret() {
  jq -Rs . | sops set --value-stdin "$FLAKE/hosts/$HOSTNAME/secrets.json" \
    "$(jq -rn --arg k "$1" '$k | split("/") | map("[\(tojson)]") | join("")')"
}

# whether the config puts the host on the tailnet (modules/core/tailnet.nix): true, false, or
# nothing while it doesn't evaluate
joinsTailnet() {
  nixx eval "$FLAKE#nixosConfigurations.$HOSTNAME.config.services.tailscale.enable" 2>/dev/null || true
}

writeSecrets() {
  local hash pwd tailscale="" joins label="Tailscale auth key (admin console: Settings → Keys)"
  # host.toml, the hardware report and cluster.toml are written, which is all this needs
  joins="$(joinsTailnet)"

  if [[ $PRESERVE == true ]]; then
    logInfo "Keeping the existing secrets"
    # auth keys expire, and the reinstalled host logs in to the tailnet anew
    if [[ $joins == true ]] && formConfirm "Replace the Tailscale auth key?" no; then
      formPassword tailscale "$label" false 1 || die "Stopped; hosts/$HOSTNAME is partly written, nothing was wiped"
      printf '%s' "$tailscale" | setSecret tailscale/authkey
      logInfo "Replaced tailscale/authkey"
    fi
    return 0
  fi

  [[ $EXISTING == true && -f $FLAKE/hosts/$HOSTNAME/secrets.json ]] && logWarn "New keys can't open the old secrets.json; it starts over"

  formPassword pwd "Login password for '$USERNAME'" || die "Stopped; hosts/$HOSTNAME is partly written, nothing was wiped"
  hash="$(printf '%s' "$pwd" | mkpasswd --stdin)"

  case "$joins" in
    true) formPassword tailscale "$label; $HOSTNAME joins the tailnet" false 0 || die "Stopped; hosts/$HOSTNAME is partly written, nothing was wiped" ;;
    false) logInfo "$HOSTNAME doesn't join the tailnet; it needs no Tailscale key" ;;
    *) formPassword tailscale "$label, empty if this host doesn't join the tailnet" false 0 || die "Stopped; hosts/$HOSTNAME is partly written, nothing was wiped" ;;
  esac

  jq -n \
    --arg pw "$hash" \
    --rawfile key "$TEMP_DIR/id_ed25519" \
    --arg tailscale "$tailscale" \
    '{"user": {"password": $pw, "private-key": $key}}
      + if $tailscale == "" then {} else {"tailscale": {"authkey": $tailscale}} end' \
    > "$FLAKE/hosts/$HOSTNAME/secrets.json"

  run sops --encrypt --in-place "$FLAKE/hosts/$HOSTNAME/secrets.json"
  git -C "$FLAKE" add --intent-to-add "hosts/$HOSTNAME/secrets.json"
  logInfo "Encrypted secrets"
}

# per missing secret: a random value, one typed in, or back to the menu to edit them by hand
fillSecrets() {
  local key how value
  local -a ways
  for key in "$@"; do
    # an auth key comes from Tailscale's admin console, the login password is a hash of a typed one
    ways=(generate enter "edit by hand")
    if [[ $key == tailscale/authkey || $key == user/password ]]; then
      ways=(enter "edit by hand")
    fi
    formChoose how "$key" "${ways[@]}" || return 1
    case "$how" in
      generate) value="$(head -c 48 < <(tr -dc 'A-Za-z0-9' < /dev/urandom))" ;;
      enter)
        if [[ $key == user/password ]]; then
          formPassword value "Login password for '$USERNAME'" || return 1
          value="$(printf '%s' "$value" | mkpasswd --stdin)"
        else
          formPassword value "$key" false 1 || return 1
        fi
        ;;
      *) return 1 ;;
    esac
    printf '%s' "$value" | setSecret "$key"
    logInfo "Added $key"
  done
}

# ── write cluster.toml ────────
# This host's relations as gatherCluster has them. Only the entries that change are rewritten,
# one by one, so yq keeps the comments and the order of the rest.
writeCluster() {
  local file="$FLAKE/cluster.toml" before want op table key value
  before="$(clusterJson)"
  want="$(jq -c --arg h "$HOSTNAME" \
    --argjson in "$(jsonList "${SSH_IN[@]}")" \
    --argjson out "$(jsonList "${SSH_OUT[@]}")" \
    --argjson folders "$(jsonList "${SYNC_FOLDERS[@]}")" '
    # a list with this host in it, or without; where it already is, it stays
    def relate($on): if $on then (if any(.[]; . == $h) then . else . + [$h] end) else map(select(. != $h)) end;
    (.ssh // {}) as $ssh | (.sync // {}) as $sync
    | {
        ssh: (reduce ((($ssh | keys) + $in) | unique[]) as $m ({};
            .[$m] = (($ssh[$m] // []) | relate(any($in[]; . == $m))))
          | if $out == [] then del(.[$h]) else .[$h] = $out end),
        sync: (reduce ($sync | keys[]) as $f ({}; .[$f] = ($sync[$f] | relate(any($folders[]; . == $f)))))
      }' <<< "$before")"

  if [[ "$(jq -S '{ssh: (.ssh // {}), sync: (.sync // {})}' <<< "$before")" == "$(jq -S . <<< "$want")" ]]; then
    return 0
  fi

  [[ -f $file ]] || : > "$file"
  cp "$file" "$TEMP_DIR/cluster.toml"
  while IFS=$'\t' read -r op table key value; do
    if [[ $op == set ]]; then
      T="$table" K="$key" V="$value" yq -i -p toml -o toml '.[strenv(T)][strenv(K)] = env(V)' "$file"
    else
      T="$table" K="$key" yq -i -p toml -o toml 'del(.[strenv(T)][strenv(K)])' "$file"
    fi
  done < <(jq -r --argjson want "$want" '
    . as $before | ("ssh", "sync") as $t
    | (($before[$t] // {}) + $want[$t]) | keys[]
    | . as $k
    | if ($want[$t] | has($k) | not) then ["del", $t, $k]
      elif $before[$t][$k] != $want[$t][$k] then ["set", $t, $k, ($want[$t][$k] | tojson)]
      else empty end
    | @tsv' <<< "$before")

  if [[ "$(tomlJson "$file" | jq -S '{ssh: (.ssh // {}), sync: (.sync // {})}')" != "$(jq -S . <<< "$want")" ]]; then
    cp "$TEMP_DIR/cluster.toml" "$file"
    logWarn "cluster.toml: the relations didn't come out as chosen, so it is left as it was; edit it in the next step"
    return 0
  fi
  git -C "$FLAKE" add --intent-to-add cluster.toml
  logInfo "Wrote $HOSTNAME's relations into cluster.toml"
}

# ── write host.toml ────────
writeHostToml() {
  local file="$FLAKE/hosts/$HOSTNAME/host.toml" state i devices

  if [[ $EXISTING == true ]]; then
    # keep everything hand-written; only what the installer owns changes
    tomlSet "$file" host key "\"$HOST_KEY\""
    tomlSet "$file" user key "\"$USER_KEY\""
    if [[ $REDO_DISK == true ]]; then
      tomlSet "$file" disk.boot devices "$(tomlList "$DISK")"
      tomlSet "$file" disk.boot swap "$SWAP"
      # host.toml's default, 0, is left out unless the file has a reserve to change
      if (( RESERVE > 0 )) || [[ "$(tomlJson "$file" | jq '.disk.boot | has("reserve")')" == true ]]; then
        tomlSet "$file" disk.boot reserve "$RESERVE"
      fi
    fi
    [[ -n $SYNC_ID ]] && tomlSet "$file" sync id "\"$SYNC_ID\""
    logInfo "Updated host.toml"
    return 0
  fi

  state="$(nixx eval --raw --inputs-from "$FLAKE" nixpkgs#lib.trivial.release)"

  {
    echo "[host]"
    echo "class = \"$CLASS\""
    echo "features = $(tomlList "${FEATURES[@]}")"
    echo "state = \"$state\" # written once at install, never changed"
    echo "key = \"$HOST_KEY\""
    echo
    echo "[user]"
    echo "name = \"$USERNAME\""
    echo "email = \"$USEREMAIL\""
    echo "key = \"$USER_KEY\""
    echo
    # language, keyboard and reserve only where they aren't host.toml's defaults
    echo "[locale]"
    echo "timezone = \"$TIMEZONE\""
    [[ $LOCALE != "en_US.UTF-8" ]] && echo "language = \"$LOCALE\""
    [[ $KEYBOARD != us ]] && echo "keyboard = \"$KEYBOARD\""
    [[ -n $KEYBOARD_VARIANT ]] && echo "variant = \"$KEYBOARD_VARIANT\""
    if (( ${#QUIRKS[@]} > 0 )); then
      echo
      echo "[hardware]"
      echo "quirks = $(tomlList "${QUIRKS[@]}")"
    fi
    echo
    echo "[disk.boot]"
    echo "devices = $(tomlList "$DISK")"
    echo "swap = $SWAP"
    (( RESERVE > 0 )) && echo "reserve = $RESERVE"
    for i in "${!DATA_LABELS[@]}"; do
      read -ra devices <<< "${DATA_DEVICES[$i]}"
      echo
      echo "[disk.${DATA_LABELS[$i]}]"
      echo "devices = $(tomlList "${devices[@]}")"
      [[ ${DATA_PROFILES[$i]} != single ]] && echo "profile = \"${DATA_PROFILES[$i]}\""
      echo "mounts = ${DATA_MOUNTS[$i]}"
    done
    if [[ -n $SYNC_ID ]]; then
      echo
      echo "[sync]"
      echo "id = \"$SYNC_ID\""
    fi
  } > "$file"

  git -C "$FLAKE" add --intent-to-add "hosts/$HOSTNAME/host.toml"
  logInfo "Wrote host.toml"
}

# ── hardware report ────────
writeFacter() {
  local file="$FLAKE/hosts/$HOSTNAME/facter.json"

  if [[ $EXISTING == true && -s $file ]] && ! formConfirm "Regenerate the hardware report?" no; then
    return 0
  fi

  while ! probe nix --extra-experimental-features "nix-command flakes" run nixpkgs#nixos-facter > "$file.tmp"; do
    rm -f "$file.tmp"
    if [[ $REMOTE == true ]] && ! isInstaller; then
      logWarn "The target can't run nixos-facter (no nix?)"
      formConfirm "Switch it into the installer in RAM now and try there? Nothing on its disks changes" yes \
        || die "Hardware report: none; hosts/$HOSTNAME is partly written, nothing was wiped"
      kexecTarget
    else
      die "Hardware report: nixos-facter failed (above); hosts/$HOSTNAME is partly written, nothing was wiped"
    fi
  done
  mv "$file.tmp" "$file"

  git -C "$FLAKE" add --intent-to-add "hosts/$HOSTNAME/facter.json"
  logInfo "Wrote the hardware report"
}

# ── write dotfiles ────────
writeDotfiles() {
  local dest="$FLAKE/hosts/$HOSTNAME/home"

  [[ -n $DOTFILES ]] || return 0
  mkdir -p "$dest"

  if [[ $DOTFILES_METHOD == "path" ]]; then
    run cp -rT "$DOTFILES" "$dest"
  else
    run git clone --recurse-submodules "$DOTFILES" "$TEMP_DIR/home" \
      || die "Dotfiles: can't clone $DOTFILES (above); nothing was wiped"
    run cp -rT "$TEMP_DIR/home" "$dest"
  fi

  find "$dest" -name .git -prune -exec rm -rf {} +
  rm -f "$dest/.gitmodules"

  git -C "$FLAKE" add --intent-to-add "hosts/$HOSTNAME/home"
  logInfo "Copied dotfiles"
}

# ── writing all host relevant files ────────
write() {
  formHeader "Writing files"

  mkdir -p "$FLAKE/hosts/$HOSTNAME"

  writeSopsYaml
  writeHostToml
  writeFacter
  writeCluster
  writeSecrets
  [[ $EXISTING != true ]] && writeDotfiles

  return 0
}

# ── what the questions don't cover ────────
# Both have to be in place before the install: disko formats disks only now, and one missing
# secret stops sops-nix from installing any of them at boot, the Tailscale key included.
complete() {
  formHeader "Before installing"
  logInfo "host.toml: feature tables ([gateway], …), and data disks ([disk.<label>]) for an existing host"
  logInfo "secrets.json: what the features need; the check offers to generate or ask for anything missing"

  local what log="$TEMP_DIR/eval.log" again=false
  local -a missing
  while :; do
    if [[ $again == true ]]; then
      what="Check and continue"
      again=false
    else
      what=$(gum choose --header="Edit, or check and go on" "Check and continue" \
        "Edit host.toml" "Edit cluster.toml" "Edit secrets.json" "Show host.toml") || die "Cancelled"
    fi
    case "$what" in
      "Edit host.toml") "${EDITOR:-nano}" "$FLAKE/hosts/$HOSTNAME/host.toml" ;;
      "Edit cluster.toml")
        "${EDITOR:-nano}" "$FLAKE/cluster.toml"
        [[ -f $FLAKE/cluster.toml ]] && git -C "$FLAKE" add --intent-to-add cluster.toml
        ;;
      # sops ends with 200 when the file is closed unchanged
      "Edit secrets.json") sops "$FLAKE/hosts/$HOSTNAME/secrets.json" || true ;;
      "Show host.toml") gum pager < "$FLAKE/hosts/$HOSTNAME/host.toml" ;;
      "Check and continue")
        logInfo "Evaluating the configuration"
        if nixx eval --raw "$FLAKE#nixosConfigurations.$HOSTNAME.config.system.build.toplevel.drvPath" \
            2>&1 >/dev/null | tee "$log" >&2; then
          logInfo "It evaluates"
          break
        fi
        # the secrets core/secrets.nix names: "secrets.json: missing 'a/b', 'c'; add them …"
        mapfile -t missing < <(grep -o "secrets\.json: missing '[^;]*" "$log" | grep -o "'[^']*'" | tr -d "'")
        if (( ${#missing[@]} > 0 )) && fillSecrets "${missing[@]}"; then
          again=true
          continue
        fi
        logWarn "It doesn't evaluate (above); fix it, or stop with Ctrl-C: hosts/$HOSTNAME is written, nothing was wiped"
        ;;
    esac
  done
}

# ── data disks ────────
# disko formats a data disk only while it holds no filesystem (core/storage.nix never wipes one),
# and then with mkfs.btrfs -f, over any partitions on it. So each one is looked at first: btrfs
# with its table's label is kept, an empty one is formatted, anything else is wiped on a typed yes
# or the install stops.
gatherWipe() {
  WIPE=()
  local json label d fs fstype fslabel pttype
  local -a labels devices kept=()
  json="$(tomlJson "$FLAKE/hosts/$HOSTNAME/host.toml")"
  mapfile -t labels < <(jq -r '.disk // {} | keys[] | select(. != "boot")' <<< "$json")
  (( ${#labels[@]} > 0 )) || return 0

  formHeader "Data disks"
  for label in "${labels[@]}"; do
    mapfile -t devices < <(jq -r --arg l "$label" '.disk[$l].devices[]' <<< "$json")
    for d in "${devices[@]}"; do
      probe test -b "$d" || die "disk.$label: no $d on ${TARGET:-this machine}; plug it in, or take it out of host.toml"
      probe lsblk -f "$d"
      fs="$(probe lsblk -dJo FSTYPE,LABEL,PTTYPE "$d")"
      fstype="$(jq -r '.blockdevices[0].fstype // ""' <<< "$fs")"
      fslabel="$(jq -r '.blockdevices[0].label // ""' <<< "$fs")"
      pttype="$(jq -r '.blockdevices[0].pttype // ""' <<< "$fs")"
      if [[ $fstype == btrfs && $fslabel == "$label" ]]; then
        kept+=("$d")
      elif [[ -z $fstype && -z $pttype ]]; then
        logInfo "disk.$label: $d is empty and gets formatted"
      else
        logWarn "disk.$label: $d holds ${fstype:-a $pttype partition table}${fslabel:+ labelled $fslabel}, not btrfs labelled $label"
        typedYes "Type the host name to wipe $d; everything on it is lost" \
          || die "disk.$label: $d isn't wiped, so nothing is; wipe it by hand, or take it out of host.toml"
        WIPE+=("$d")
      fi
    done
  done

  (( ${#kept[@]} > 0 )) || return 0
  logInfo "Kept as they are, with their data: ${kept[*]}"
  if formConfirm "Wipe these too? Everything on them is lost" no; then
    formTypeName "Type the host name to wipe them"
    WIPE+=("${kept[@]}")
  fi
}

wipeExtra() {
  local d
  for d in "${WIPE[@]}"; do
    # shellcheck disable=SC2016
    run probe sh -c 'for p in "$1"-part*; do [ -e "$p" ] && wipefs -a "$p"; done; wipefs -a "$1"' _ "$d"
  done
  (( ${#WIPE[@]} == 0 )) || logInfo "Wiped ${WIPE[*]}"
}

# a FAT backup boot sector survives disko's wipefs: blkid still sees vfat, disko skips
# mkfs.vfat and mounting /boot fails. Zero the start of the disk first.
zeroBootDisk() {
  probe umount -R /mnt 2>/dev/null || true
  run probe dd if=/dev/zero of="$DISK" bs=1M count=1100 conv=fsync status=none
}

# ── remote: into the installer in RAM ────────
kexecTarget() {
  local addr="${TARGET#*@}" pid found="" i ip

  logWarn "Switching $TARGET into the installer; until the install, a reboot brings the old system back"
  ssh -o ControlPath="$TEMP_DIR/ssh-%C" -O exit "$TARGET" &>/dev/null || true

  # nixos-anywhere waits for the installer at the old address forever, but DHCP may hand it
  # another one: it runs in its own session (stopping it stops its ssh too) while the installer is
  # looked for by its network card. --flake is required even here; only disko and install build.
  setsid nix --extra-experimental-features "nix-command flakes" run --inputs-from "$FLAKE" \
    nixpkgs#nixos-anywhere -- --phases kexec --flake "$FLAKE#$HOSTNAME" --target-host "$TARGET" \
    </dev/null &
  pid=$!

  # the installer has a host key of its own
  ssh-keygen -R "$addr" -f "$TEMP_DIR/known_hosts" &>/dev/null || true

  for (( i = 0; i < 90; i++ )); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || die "Installer in RAM: the switch failed (above); nothing was wiped"
      found="$addr"
      break
    fi
    # after a minute, the old system is gone and the installer has asked for an address
    if [[ -n $TARGET_MAC ]] && (( i >= 6 && i % 3 == 0 )); then
      while IFS= read -r ip; do
        [[ $ip != "$addr" ]] || continue
        if ssh -n "${SSH_OPTS[@]}" -o BatchMode=yes "root@$ip" \
            "grep -Eq 'VARIANT_ID=\"?installer\"?' /etc/os-release" 2>/dev/null; then
          found="$ip"
          break
        fi
      done < <(findByMac "$TARGET_MAC" "$TARGET_NET")
      if [[ -n $found ]]; then
        kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        logInfo "The installer came up at $found instead of $addr"
        break
      fi
    fi
    sleep 10
  done

  if [[ -z $found ]]; then
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    die "Installer in RAM: $addr didn't come back as the installer, at that address or any other; nothing was wiped, a reboot brings the old system back, and a rerun reuses this run's keys"
  fi

  TARGET="root@$found"
  isInstaller || die "Installer in RAM: $TARGET doesn't run the installer; nothing was wiped"
  logInfo "$TARGET runs the installer"
}

# Everything the machine needs on disk before first boot
stageFiles() {
  local root="$1"
  local ssh="$root/persist/etc/ssh" home="$root/home/$USERNAME" sync="$TEMP_DIR/syncthing"

  install -d -m 755 "$ssh"
  install -m 644 "$TEMP_DIR/ssh_host_ed25519_key.pub" "$ssh/ssh_host_ed25519_key.pub"
  install -m 600 "$TEMP_DIR/ssh_host_ed25519_key" "$ssh/ssh_host_ed25519_key"

  # the target's network connections (the installer's Wi-Fi), where core/network.nix keeps them.
  # Both installs copy the stage as root, so they end up root's; NetworkManager skips a
  # connection file that isn't mode 0600.
  local nm="$root/persist/etc/NetworkManager/system-connections"
  install -d -m 700 "$nm"
  probe sh -c 'cd /etc/NetworkManager/system-connections && tar -cf - -- *.nmconnection' 2>/dev/null \
    | tar -C "$nm" -xf - 2>/dev/null || true
  find "$nm" -type f -exec chmod 600 {} +

  install -d -m 700 "$home/.ssh"
  install -m 644 "$TEMP_DIR/id_ed25519.pub" "$home/.ssh/id_ed25519.pub"
  install -m 600 "$TEMP_DIR/id_ed25519" "$home/.ssh/id_ed25519"

  # the checkout, where axon.repo expects it: a clone of the commit that holds this host
  local branch key value
  git clone -q "$FLAKE" "$home/axon"
  # its origin is this checkout. With cluster.toml [repo.remotes] the system git config holds the
  # remotes (copying them too would give each two urls); without, it gets this checkout's
  git -C "$home/axon" remote remove origin
  if [[ "$(clusterJson | jq '(.repo.remotes // {}) != {}')" != true ]]; then
    while read -r key value; do
      git -C "$home/axon" config --add "$key" "$value"
    done < <(git -C "$FLAKE" config --get-regexp '^remote\.')
  fi
  branch="$(git -C "$FLAKE" branch --show-current)"
  for key in remote merge; do
    value="$(git -C "$FLAKE" config "branch.$branch.$key")" || continue
    git -C "$home/axon" config "branch.$branch.$key" "$value"
  done

  # Syncthing's keys where the config persists them: under /persist, or on the state volume
  SYNC_PATH=""
  if [[ -s $sync/cert.pem ]]; then
    if syncPlace; then
      SYNC_PATH="$SYNC_ROOT$SYNC_DIR"
      install -d -m 700 "$root$SYNC_PATH"
      install -m 600 "$sync/cert.pem" "$sync/key.pem" "$root$SYNC_PATH/"
    else
      logWarn "$HOSTNAME persists no Syncthing folder; its keys aren't installed"
    fi
  fi
}

# ── commit ────────
# The new host is cloned from this commit, so both sides have the same history and its
# first pull is a fast-forward. Only the host's files go in, with cluster.toml and .sops.yaml;
# nothing else staged or changed.
commitHost() {
  local paths=("hosts/$HOSTNAME" .sops.yaml) verb=install
  local -a identity=()
  [[ $EXISTING == true ]] && verb=reinstall
  [[ -f $FLAKE/cluster.toml ]] && paths+=(cluster.toml)
  # the installer's git has no identity of its own: the commit goes in under the host's user
  git -C "$FLAKE" config user.name >/dev/null || identity+=(-c "user.name=$USERNAME")
  git -C "$FLAKE" config user.email >/dev/null || identity+=(-c "user.email=$USEREMAIL")

  git -C "$FLAKE" add -- "${paths[@]}"
  if git -C "$FLAKE" diff --cached --quiet -- "${paths[@]}"; then
    logInfo "hosts/$HOSTNAME is committed already"
    return 0
  fi
  git -C "$FLAKE" "${identity[@]}" commit -q -m "feat($HOSTNAME): $verb" -- "${paths[@]}" \
    || die "Commit: git refused it (above); nothing was wiped"
  logInfo "Committed hosts/$HOSTNAME: $(git -C "$FLAKE" log -1 --format='%h %s')"
}

# ── install ────────
installSystem() {
  formHeader "Installing"
  # host.toml's boot disk, as disko formats it, edited by hand or not
  DISK="$(tomlJson "$FLAKE/hosts/$HOSTNAME/host.toml" | jq -r '.disk.boot.devices[0]')"
  gatherWipe

  logWarn "$DISK on ${TARGET:-this machine} will be wiped"
  formTypeName "Type the host name to wipe and install"

  if [[ $REMOTE == true ]]; then
    installRemote
  else
    installLocal
  fi
}

# install via nixos-install
installLocal() {
  local stage="$TEMP_DIR/stage" disko
  mkdir -p "$stage"
  stageFiles "$stage"

  # the config's own disko script, the one nixos-anywhere runs: it wipes the boot disk and formats
  # the empty data disks. Built before anything is wiped.
  disko="$(nixx build --no-link --print-out-paths "$FLAKE#nixosConfigurations.$HOSTNAME.config.system.build.diskoScript")"
  zeroBootDisk
  wipeExtra
  run sudo "$disko"

  # the staging folders belong to the USB's user; their owners would replace those of /mnt's folders
  sudo cp -a --no-preserve=ownership "$stage/." /mnt/
  sudo chown -R 1000:100 "/mnt/home/$USERNAME"
  [[ -n $SYNC_PATH ]] && sudo chown -R 1000:100 "/mnt$SYNC_PATH"

  # the USB's tmpfs is too small for a first build
  sudo mkdir -p /mnt/tmp
  export TMPDIR=/mnt/tmp
  sudo systemctl set-environment TMPDIR=/mnt/tmp
  sudo systemctl restart nix-daemon

  logWarn "First install can take a while"
  sudo nixos-install --root /mnt --flake "$FLAKE#$HOSTNAME" --no-root-passwd

  logInfo "Installed $HOSTNAME"
  finish
  if formConfirm "Reboot now?" yes; then
    sudo reboot
  else
    logInfo "Not rebooted; $HOSTNAME starts with the next boot"
  fi
}

# Install via nixos-anywhere
installRemote() {
  local stage="$TEMP_DIR/stage"
  mkdir -p "$stage"
  stageFiles "$stage"

  local -a owners=(--chown "/home/$USERNAME" 1000:100)
  [[ -n $SYNC_PATH ]] && owners+=(--chown "$SYNC_PATH" 1000:100)

  isInstaller || kexecTarget
  zeroBootDisk
  wipeExtra

  logWarn "First install can take a while"
  nixx run --inputs-from "$FLAKE" nixpkgs#nixos-anywhere -- \
    --phases disko,install,reboot \
    --flake "$FLAKE#$HOSTNAME" \
    --extra-files "$stage" \
    "${owners[@]}" \
    --target-host "$TARGET"

  verifyRemote || true
  finish
}

verifyRemote() {
  local addr="${TARGET#*@}" ok=false i ip
  local -a candidates

  # Pin the key we generated, so this proves identity as well as reachability. By name, not
  # address: the installed system asks DHCP again and may come back elsewhere.
  printf '%s %s\n' "$HOSTNAME" "$HOST_KEY" > "$TEMP_DIR/known_hosts"

  logInfo "Waiting for $HOSTNAME to reboot"
  for (( i = 0; i < 60; i++ )); do
    candidates=("$addr")
    if [[ -n $TARGET_MAC ]] && (( i >= 6 && i % 3 == 0 )); then
      mapfile -t -O 1 candidates < <(findByMac "$TARGET_MAC" "$TARGET_NET")
    fi
    for ip in "${candidates[@]}"; do
      if ssh -o StrictHostKeyChecking=yes -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=10 \
          -o HostKeyAlias="$HOSTNAME" -o UserKnownHostsFile="$TEMP_DIR/known_hosts" \
          "$USERNAME@$ip" true 2>/dev/null; then
        ok=true
        TARGET="root@$ip"
        break 2
      fi
    done
    sleep 5
  done

  if [[ $ok == true ]]; then
    logInfo "Host key verified, logged in as $USERNAME at ${TARGET#*@}"
  else
    logWarn "Couldn't log in to $HOSTNAME as $USERNAME. It may still be booting, or cluster.toml"
    logWarn "[ssh] doesn't let this machine's key in yet; try ssh $USERNAME@$addr with the password"
    return 1
  fi
}

finish() {
  # installed: the keys are on the machine now
  rm -rf "$(keepDir)"

  {
    printf '%-10s %s\n' host "$HOSTNAME"
    [[ $REMOTE == true ]] && printf '%-10s %s\n' ssh "ssh $USERNAME@${TARGET#*@}"
    echo
    if [[ $REMOTE == true ]]; then
      echo "Publish the commit with the new host, from this checkout:"
    else
      echo "This checkout goes with the installer. After the first boot, publish"
      echo "the commit with the new host from ~/axon on $HOSTNAME:"
    fi
    echo "  git push"
    if [[ -n $(git -C "$FLAKE" status --porcelain) ]]; then
      echo "Other changes here aren't committed; $HOSTNAME's checkout doesn't have them"
      echo "until they are committed and pushed"
    fi
    echo "Then rebuild the other hosts, so they trust its keys and know its relations."
    echo "$HOSTNAME pulls from the forges with its own key ($USERNAME@$HOSTNAME)"
    echo "or one your SSH agent forwards; if its pull fails, add that key there"
  } | gum style --border=rounded --padding="1 2" --margin="1 0"
  if [[ $REMOTE == true ]]; then
    logWarn "If your known_hosts has an old key for the target: ssh-keygen -R ${TARGET#*@}"
  fi
}

# ── main ────────
main() {
  parseArgs "$@"

  # sudo is called where it's needed; as root, hosts/<name> and the repo copy would be root-owned
  if [[ $EUID -eq 0 ]]; then
    echo "install.sh: don't run as root; run it as your user, it calls sudo itself" >&2
    exit 1
  fi
  # local mode wipes this machine's disks: only safe while it runs from the installer
  if [[ $REMOTE == false ]] && ! grep -Eq 'VARIANT_ID="?installer"?' /etc/os-release; then
    echo "install.sh: run it from the NixOS installer, or with -r for a remote machine" >&2
    exit 1
  fi

  shell "$@"
  clear

  if [[ $VERBOSE == true ]]; then
    export GUM_LOG_LEVEL=debug
  else
    export GUM_LOG_LEVEL=info
  fi

  FLAKE=$(dirname -- "$(readlink -f -- "$0")")
  cd "$FLAKE"

  TEMP_DIR="$(TMPDIR=/tmp mktemp -d)"
  chmod 700 "$TEMP_DIR"

  [[ $REMOTE == false ]] && sudo -v
  sshInit

  REGISTRY="$(nixx eval --json "$FLAKE#axon")" || die "flake.nix: the flake doesn't evaluate (above); fix that first"

  gather
  generate
  write
  complete
  commitHost
  installSystem
}

main "$@"
