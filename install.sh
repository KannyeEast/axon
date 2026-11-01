#!/usr/bin/env bash
#
# install.sh: put a machine into the repo and install it
#
#   ./install.sh        this machine, booted from the NixOS installer USB
#   ./install.sh -r     another machine over SSH, through nixos-anywhere. It may run the
#                       installer or any Linux: a running system is switched into the
#                       installer in RAM first. Needs key login as root.
#
# It asks a few questions, writes hosts/<name>/ (host.toml, facter.json, secrets.json) and the
# machine's keys into .sops.yaml, lets you add what the questions don't cover (the features'
# tables and secrets), checks that the config evaluates, and only then wipes and
# installs. An existing hosts/<name> is reinstalled with its settings, and keeps its keys when
# the old system still has them.

set -Eeuo pipefail

# ── script variables ────────
# == flags ==
VERBOSE=false
REMOTE=false

# == host ==
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

# == disk ==
DISK=""
DISK_NAME=""
SWAP=""
RESERVE=0
WIPE_EXTRA=false

# == data disks: one entry per [disk.<label>] ==
DATA_LABELS=()
DATA_DEVICES=()
DATA_PROFILES=()
DATA_MOUNTS=()

# == secrets ==
HOST_AGE=""
USER_AGE=""

# == temp ==
FLAKE=""
TEMP_DIR=""
DOTFILES_METHOD=""
DOTFILES=""
SSH_OPTS=()
TARGET=""
REGISTRY=""

# ── theme ────────
# == palette ==
FG="#c6c8d1"
MUTED="#6c7086"
CURSOR="#7aa2f7"
ACCENT="#9ece6a"
BASE="#1a1b26"

# == gum ==
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

# == wrap command in gum styling ==
run() {
  if [[ $VERBOSE == true ]]; then
    logDebug "\$ $*"
    "$@"
  else
    gum spin --title "$*" --show-error -- "$@"
  fi
}

nixx() { nix --extra-experimental-features "nix-command flakes" "$@"; }

# == multiplexing ==
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

# == decide where to execute command; local commands run as root, like remote ones ==
probe() {
  if [[ $REMOTE == true ]]; then
    ssh "${SSH_OPTS[@]}" "$TARGET" "$(printf '%q ' "$@")"
  else
    sudo "$@"
  fi
}

# == the target runs the NixOS installer (USB or nixos-anywhere's kexec), not an installed system ==
isInstaller() {
  # the same test nixos-anywhere makes
  probe grep -Eq 'VARIANT_ID="?installer"?' /etc/os-release
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
declare -A MODULE_PKGS=(
  [base]="gum git jq yq-go gawk"
  [secrets]="mkpasswd openssh sops ssh-to-age syncthing"
  [disk]="disko"
)

shell() {
  if [[ -z ${INSTALLER_SHELL:-} ]]; then
    local modules mod pkgs=() flake
    flake=$(dirname -- "$(readlink -f -- "$0")")

    modules=("base" "secrets")
    [[ $REMOTE == false ]] && modules+=("disk")

    for mod in "${modules[@]}"; do
      # shellcheck disable=SC2206
      pkgs+=(${MODULE_PKGS[$mod]})
    done

    printf "Fetching dependencies ...\n"
    # locale -a and the layout list read these instead of the host's
    LOCALE_ARCHIVE="$(nixx build --no-link --print-out-paths --inputs-from "$flake" nixpkgs#glibcLocales)/lib/locale/locale-archive"
    XKB_RULES="$(nixx build --no-link --print-out-paths --inputs-from "$flake" nixpkgs#xkeyboard_config)/share/X11/xkb/rules/base.lst"
    export LOCALE_ARCHIVE XKB_RULES INSTALLER_SHELL=1

    exec nix --extra-experimental-features "nix-command flakes" shell --inputs-from "$flake" \
      "${pkgs[@]/#/nixpkgs#}" -c bash "$0" "$@"
  fi
}

# ── gum wrappers ────────
formHeader() {
  gum style --bold --foreground="$FG" \
    --border=rounded --border-foreground="$MUTED" \
    --padding="0 2" --margin="1 0" "$*"
}

formInput() {
  local __var="$1" label="$2" placeholder="${4:-${3:-$2}}" value
  while :; do
    value=$(gum input --header="$label" --placeholder="$placeholder" --value="${3:-}") || die "Cancelled"
    [[ -n $value ]] && break
    logWarn "$label cannot be empty"
  done
  printf -v "$__var" '%s' "$value"
  gum style --foreground="$MUTED" "$label: $value"
}

formInputOpt() {
  local __var="$1" label="$2" placeholder="${3:-$2}" value
  value=$(gum input --header="$label" --placeholder="$placeholder") || true
  printf -v "$__var" '%s' "$value"
  gum style --foreground="$MUTED" "$label: ${value:-skip}"
}

formPassword() {
  local __var="$1" label="$2" confirm="${3:-true}" minlen="${4:-8}" pw pw2
  while :; do
    pw=$(gum input --password --header="$label" --placeholder="$label") || die "Cancelled"
    (( ${#pw} >= minlen )) || { logWarn "Min $minlen characters"; continue; }
    [[ $confirm == true ]] || break
    pw2=$(gum input --password --header="Repeat $label" --placeholder="Repeat $label") || die "Cancelled"
    [[ $pw == "$pw2" ]] && break
    logWarn "Mismatch — try again"
  done
  printf -v "$__var" '%s' "$pw"
}

formChoose() {
  local __var="$1" label="$2"; shift 2
  local selected
  selected=$(gum choose --header="$label" --selected="$1" --height=15 "$@") || die "Cancelled"
  printf -v "$__var" '%s' "$selected"
  gum style --foreground="$MUTED" "$label: $selected"
}

formMulti() {
  local __var="$1" label="$2"; shift 2
  local selected
  selected=$(gum choose --no-limit --header="$label" --height=15 "$@") || true
  local -n __ref="$__var"
  if [[ -n $selected ]]; then mapfile -t __ref <<< "$selected"; else __ref=(); fi
  gum style --foreground="$MUTED" "$label: ${__ref[*]:-none}"
}

formConfirm() {
  local label="$1" default="${2:-n}"
  case "$default" in
    y|yes|1) default=true ;;
    *)       default=false ;;
  esac
  if gum confirm --default="$default" "$label"; then
    gum style --foreground="$MUTED" "$label: yes"
    return 0
  else
    gum style --foreground="$MUTED" "$label: no"
    return 1
  fi
}

formFilter() {
  local __var="$1" label="$2" options="$3" placeholder="${4:-$2}" selected
  [[ -n $options ]] || return 1
  selected=$(gum filter \
    --header="$label" \
    --height=15 \
    --placeholder="$placeholder" <<< "$options") || die "Cancelled"
  printf -v "$__var" '%s' "$selected"
  gum style --foreground="$MUTED" "$label: $selected"
}

# == the host name typed back: the last stop before anything is wiped ==
formTypeName() {
  local label="$1" reply
  reply=$(gum input --header="$label" --placeholder="type $HOSTNAME") || die "Cancelled"
  [[ $reply == "$HOSTNAME" ]] || die "Stopped; hosts/$HOSTNAME is written, nothing was wiped"
}

# ── toml ────────
tomlJson() { yq -p toml -o json '.' "$1"; }

# == set KEY in [SECTION] to a raw TOML value, adding the key or the section if missing ==
tomlSet() {
  local file="$1" section="$2" key="$3" value="$4"
  awk -v s="[$section]" -v k="$key" -v v="$value" '
    function add() { if (insec && !done) { print k " = " v; done = 1 } }
    /^\[/ { add(); insec = ($0 == s) }
    insec && index($0, k " ") == 1 && $0 ~ ("^" k "[ ]*=") { print k " = " v; done = 1; next }
    { print }
    END {
      add()
      if (!done) { print ""; print s; print k " = " v }
    }' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

tomlList() { # bash array -> TOML array of strings
  local out="" item
  for item in "$@"; do out+="\"$item\", "; done
  printf '[%s]' "${out%, }"
}

# ── filter lists ────────
# == nixos-hardware modules ==
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

# == timezones ==
listSupportedTimezones() {
  local zones=""
  zones=$(timedatectl list-timezones 2>/dev/null || true)

  if [[ -z $zones ]]; then
    zones=$(find /usr/share/zoneinfo /etc/zoneinfo -type f -printf '%P\n' 2>/dev/null \
      | grep -v -E '^(posix|right|Etc)/' | sort -u || true)
  fi

  printf '%s\n' "$zones"
}

# == locale ==
listSupportedLocales() {
  command -v locale &>/dev/null || return 1
  locale -a 2>/dev/null \
    | grep -iE '\.utf-?8$' \
    | sed -E 's/\.utf-?8$/.UTF-8/I' \
    | sort -u
}

# == keyboard layouts ==
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

# == disks ==
listDisks() {
  probe lsblk -dno NAME,SIZE,MODEL -e 7,11 | awk 'NF'
}

# == a disk's by-id path, which survives disks being renumbered ==
diskId() {
  local name="$1" byid
  byid="$(probe ls -l /dev/disk/by-id/ | awk -v d="$name" \
    '$NF ~ ("/" d "$") && $9 !~ /-part|^wwn-|^nvme-eui/ {print "/dev/disk/by-id/" $9; exit}' || true)"
  [[ -n $byid ]] || byid="$(probe ls -l /dev/disk/by-id/ | awk -v d="$name" \
    '$NF ~ ("/" d "$") && $9 !~ /-part/ {print "/dev/disk/by-id/" $9; exit}' || true)"
  printf '%s' "${byid:-/dev/$name}"
}

# == list directories ==
listDirs() {
  find / -xdev -maxdepth 6 -type d \
    \( -path /nix -o -path /proc -o -path /sys -o -path /dev -o -path /run \
      -o -name .git -o -name .cache -o -name node_modules \) -prune -o \
    -type d -print 2>/dev/null | sort -u
}

# ── information gathering ────────
# == ssh target ==
gatherTarget() {
  formHeader "Target"
  TARGET=""

  while :; do
    formInput TARGET "SSH destination (root)" "" "root@192.168.1.50"
    [[ $TARGET == *@* ]] || TARGET="root@$TARGET"
    if [[ ${TARGET%%@*} != root ]]; then
      logWarn "nixos-anywhere logs in as root"
      continue
    fi

    # Key login only: after the switch into the installer a password no longer works
    if ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" true; then
      break
    fi
    logWarn "Cannot log in to $TARGET with a key. On the target, as root: add your key to"
    logWarn "/root/.ssh/authorized_keys (installer USB: passwd, then from here ssh-copy-id $TARGET)"
  done

  logInfo "Connected to $(probe hostname) running $(probe uname -sr)"
  if isInstaller; then
    logInfo "It runs the NixOS installer"
  else
    logInfo "It runs an installed system; it is switched into the installer in RAM before the install"
  fi
}

# == host ==
gatherIdentity() {
  formHeader "Identity"
  HOSTNAME=""
  EXISTING=false

  while :; do
    formInput HOSTNAME "Hostname" "" "nixos"
    if [[ ! $HOSTNAME =~ ^[a-z][a-z0-9-]{0,62}$ ]]; then
      logWarn "Lowercase letters, digits, and hyphens only"
      continue
    fi
    if [[ -d $FLAKE/hosts/$HOSTNAME ]]; then
      logInfo "hosts/$HOSTNAME already exists"
      if formConfirm "Reinstall $HOSTNAME with its settings?" "n"; then
        EXISTING=true
        break
      fi
      continue
    fi
    break
  done
}

# == reuse an existing host ==
loadHost() {
  local dir="$FLAKE/hosts/$HOSTNAME" json missing=()

  [[ -f $dir/host.toml ]] || missing+=("host.toml")
  [[ -f $dir/secrets.json ]] || missing+=("secrets.json")

  if (( ${#missing[@]} > 0 )); then
    logError "hosts/$HOSTNAME is incomplete, missing: ${missing[*]}"
    return 1
  fi

  json="$(tomlJson "$dir/host.toml")" || { logError "hosts/$HOSTNAME/host.toml doesn't parse"; return 1; }

  CLASS="$(jq -r '.host.class // empty' <<< "$json")"
  mapfile -t FEATURES < <(jq -r '.host.features[]?' <<< "$json")
  USERNAME="$(jq -r '.user.name // empty' <<< "$json")"
  USEREMAIL="$(jq -r '.user.email // empty' <<< "$json")"
  mapfile -t QUIRKS < <(jq -r '.hardware.quirks[]?' <<< "$json")
  TIMEZONE="$(jq -r '.locale.timezone // empty' <<< "$json")"
  LOCALE="$(jq -r '.locale.language // empty' <<< "$json")"
  KEYBOARD="$(jq -r '.locale.keyboard // empty' <<< "$json")"
  KEYBOARD_VARIANT="$(jq -r '.locale.variant // empty' <<< "$json")"
  DISK="$(jq -r '.disk.boot.devices[0] // empty' <<< "$json")"
  SWAP="$(jq -r '.disk.boot.swap // 8' <<< "$json")"
  RESERVE="$(jq -r '.disk.boot.reserve // 0' <<< "$json")"
  SYNC_ID="$(jq -r '.sync.id // empty' <<< "$json")"
  HOST_KEY="$(jq -r '.host.key // empty' <<< "$json")"

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
    logError "hosts/$HOSTNAME/host.toml has no user.name or host.class"
    return 1
  fi

  logInfo "Reusing hosts/$HOSTNAME"
  return 0
}

# == class and features, as the flake declares them ==
gatherRole() {
  formHeader "Role"
  CLASS=""
  FEATURES=()

  local -a classes rows picked
  local row name

  mapfile -t classes < <(jq -r '.classes | keys[]' <<< "$REGISTRY")
  formChoose CLASS "Class" "${classes[@]}"

  mapfile -t rows < <(jq -r --arg c "$CLASS" \
    '.features | to_entries[] | select(.value.classes | index($c)) | "\(.key)  \(.value.description)"' <<< "$REGISTRY")
  (( ${#rows[@]} > 0 )) || return 0

  formMulti picked "Features" "${rows[@]}"
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

# == identity of an existing host, from the old system ==
preserveIdentity() {
  formHeader "Keys"
  PRESERVE=false

  local key="$TEMP_DIR/ssh_host_ed25519_key" sync="$TEMP_DIR/syncthing"
  local src part mnt="$TEMP_DIR/oldroot"

  mkdir -p "$sync"

  if [[ $REMOTE == true ]]; then
    # the old system is still running: read its persist directly
    if isInstaller; then
      logWarn "The target already runs the installer; the old keys can't be read, they are regenerated"
      return 0
    fi
    probe cat /persist/etc/ssh/ssh_host_ed25519_key > "$key" 2>/dev/null || { rm -f "$key"; }
    probe cat /persist/var/lib/syncthing/cert.pem > "$sync/cert.pem" 2>/dev/null || rm -f "$sync/cert.pem"
    probe cat /persist/var/lib/syncthing/key.pem > "$sync/key.pem" 2>/dev/null || rm -f "$sync/key.pem"
  else
    if [[ -z $DISK || ! -e $DISK ]]; then
      logWarn "Boot disk $DISK not found, keys are regenerated"
      return 0
    fi
    part="$(lsblk -lnpo PATH,FSTYPE "$DISK" | awk '$2 == "btrfs" { print $1; exit }')"
    if [[ -z $part ]]; then
      logWarn "No btrfs partition on $DISK, keys are regenerated"
      return 0
    fi
    mkdir -p "$mnt"
    if ! sudo mount -o subvol=/persist,ro "$part" "$mnt" 2>/dev/null; then
      logWarn "Could not mount $part, keys are regenerated"
      return 0
    fi
    src="$mnt"
    # read as root, written as the user
    # shellcheck disable=SC2024
    sudo cat "$src/etc/ssh/ssh_host_ed25519_key" > "$key" 2>/dev/null || rm -f "$key"
    # shellcheck disable=SC2024
    sudo cat "$src/var/lib/syncthing/cert.pem" > "$sync/cert.pem" 2>/dev/null || rm -f "$sync/cert.pem"
    # shellcheck disable=SC2024
    sudo cat "$src/var/lib/syncthing/key.pem" > "$sync/key.pem" 2>/dev/null || rm -f "$sync/key.pem"
    sudo umount "$mnt"
  fi

  if [[ ! -s $key ]]; then
    logWarn "No host key on the old system, keys are regenerated"
    rm -f "$key"
    return 0
  fi
  chmod 600 "$key"

  # only the key host.toml names can open secrets.json
  if [[ "$(ssh-keygen -y -f "$key" | cut -d' ' -f1-2)" != "$(cut -d' ' -f1-2 <<< "$HOST_KEY")" ]]; then
    logWarn "The old system's host key isn't the one in host.toml, keys are regenerated"
    rm -f "$key"
    return 0
  fi

  PRESERVE=true
  logInfo "Recovered the host key"
}

# == user ==
gatherUser() {
  formHeader "User"
  USERNAME=""
  USEREMAIL=""

  while :; do
    formInput USERNAME "Username" "$(whoami)" "login name"
    [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && break
    logWarn "Lowercase letters, digits, hyphens, underscores; start with letter or underscore"
  done

  while :; do
    formInputOpt USEREMAIL "Email (git identity, certificate contact)" "$USERNAME@$HOSTNAME"
    [[ -n $USEREMAIL && $USEREMAIL == *@* ]] && break
    logWarn "Email cannot be empty and must contain '@'"
  done
}

# == locale ==
gatherLocale() {
  formHeader "Locale"
  TIMEZONE=""
  LOCALE=""

  if ! formFilter TIMEZONE "Timezone" "$(listSupportedTimezones)" "e.g. Europe/Berlin, America/New_York..."; then
    formInput TIMEZONE "Timezone" "Europe/Berlin"
  fi

  if ! formFilter LOCALE "Language" "$(listSupportedLocales)" "e.g. en_US.UTF-8, de_DE.UTF-8..."; then
    formInput LOCALE "Language" "en_US.UTF-8"
  fi

  if ! formFilter KEYBOARD "Keyboard layout" "$(listKeyboardLayouts)" "e.g. us, de, fr..."; then
    logWarn "No layout list available; enter one by hand"
    formInput KEYBOARD "Keyboard layout" "us"
  fi

  if ! formFilter KEYBOARD_VARIANT "Layout variant" \
      "$(listKeyboardVariants "$KEYBOARD")" "(none) for the default"; then
    KEYBOARD_VARIANT=""
  fi

  if [[ $KEYBOARD_VARIANT == "(none)" ]]; then
    KEYBOARD_VARIANT=""
  fi
}

# == hardware: facter detects the rest ==
gatherHardware() {
  formHeader "Hardware"
  QUIRKS=()

  logInfo "CPU, GPU, firmware and drivers come from the hardware report"
  formConfirm "Add a model-specific fix from nixos-hardware?" "n" || return 0

  local models selection=""
  models="$(listNixosHardwareModules || true)"

  if [[ -n $models ]] && formFilter selection "Search for your model" "$models" "e.g. framework-13-7040-amd, lenovo-thinkpad-t14..."; then
    QUIRKS+=("$selection")
  else
    logInfo "https://github.com/NixOS/nixos-hardware"
    formInputOpt selection "Module name" ""
    [[ -n $selection ]] && QUIRKS+=("$selection")
  fi

  return 0
}

# == disk ==
gatherDisk() {
  formHeader "Boot disk"
  DISK=""

  local name
  logWarn "The selected disk will be wiped"
  formFilter name "Choose disk" "$(listDisks)" "" \
    || die "No disks found"
  DISK_NAME="$(awk '{print $1}' <<< "$name")"
  DISK="$(diskId "$DISK_NAME")"
  logInfo "Disk: $DISK"
}

# == data disks: each [disk.<label>] is one btrfs filesystem, on one disk or an array ==
gatherData() {
  formHeader "Data disks"
  DATA_LABELS=()
  DATA_DEVICES=()
  DATA_PROFILES=()
  DATA_MOUNTS=()

  # the minimum device count of each profile, as modules/core/storage.nix checks it
  local -A minimum=([single]=1 [raid0]=2 [raid1]=2 [raid1c3]=3 [raid1c4]=4 [raid10]=4 [raid5]=3 [raid6]=4)
  local -a used=("$DISK_NAME") free picked devices profiles
  local label profile mounts subvol mountpoint row p

  while :; do
    mapfile -t free < <(listDisks | awk -v used=" ${used[*]} " 'index(used, " " $1 " ") == 0')
    (( ${#free[@]} > 0 )) || break
    formConfirm "Add a data disk?" "n" || break

    while :; do
      formInput label "Name (the filesystem label)" "" "bulk"
      if [[ ! $label =~ ^[a-z][a-z0-9-]*$ || $label == boot ]]; then
        logWarn "Lowercase letters, digits, and hyphens; not 'boot'"
        continue
      fi
      if printf '%s\n' "${DATA_LABELS[@]}" | grep -qx "$label"; then
        logWarn "$label is taken"
        continue
      fi
      break
    done

    formMulti picked "Disks (space to select)" "${free[@]}"
    if (( ${#picked[@]} == 0 )); then
      logWarn "No disk selected; $label is skipped"
      continue
    fi

    devices=()
    for row in "${picked[@]}"; do
      row="${row%% *}"
      used+=("$row")
      devices+=("$(diskId "$row")")
    done

    # mirrored by default once there is a second disk; only what the count allows is offered
    profiles=()
    (( ${#devices[@]} >= 2 )) && profiles+=(raid1)
    for p in single raid0 raid1 raid1c3 raid1c4 raid10 raid5 raid6; do
      [[ $p == raid1 && ${#devices[@]} -ge 2 ]] && continue
      (( ${#devices[@]} >= minimum[$p] )) && profiles+=("$p")
    done
    if (( ${#profiles[@]} > 1 )); then
      formChoose profile "Profile" "${profiles[@]}"
    else
      profile=single
    fi

    mounts=""
    subvol="$label"
    while :; do
      while :; do
        formInputOpt p "Subvolume" "$subvol"
        p="${p:-$subvol}"
        [[ $p =~ ^[a-z0-9_-]+$ ]] && break
        logWarn "Lowercase letters, digits, hyphens, underscores"
      done
      subvol="$p"
      while :; do
        formInputOpt mountpoint "Mount $subvol at" "/server/$subvol"
        mountpoint="${mountpoint:-/server/$subvol}"
        [[ $mountpoint =~ ^/[^\"\\[:space:]]*$ ]] && break
        logWarn "An absolute path without spaces or quotes"
      done
      mounts+="$subvol = \"$mountpoint\", "
      formConfirm "Another subvolume on $label?" "n" || break
      subvol=""
    done

    DATA_LABELS+=("$label")
    DATA_DEVICES+=("${devices[*]}")
    DATA_PROFILES+=("$profile")
    DATA_MOUNTS+=("{ ${mounts%, } }")
    logInfo "disk.$label: ${#devices[@]} disk(s), $profile"
  done
}

# == swap ==
gatherSwap() {
  formHeader "Swap"
  SWAP=""

  local ram swapDefault
  ram=$(( ( $(probe cat /proc/meminfo | awk '/MemTotal/{print $2}') + 524288 ) / 1048576 ))
  logInfo "Detected ${ram}GiB of RAM"

  if [[ $CLASS == desktop ]] && formConfirm "Enable hibernation?" "n"; then
    swapDefault=$(( ram + 2 ))
  elif [[ $CLASS == desktop ]]; then
    swapDefault=0
  else
    swapDefault=8
  fi

  while :; do
    formInputOpt SWAP "Swap size in GiB, 0 for none" "$swapDefault"
    SWAP="${SWAP:-$swapDefault}"
    [[ $SWAP =~ ^[0-9]+$ ]] && break
    logWarn "Enter a whole number of GiB"
  done
}

# == room for another OS ==
gatherLayout() {
  formHeader "Layout"
  RESERVE=0

  local totalGiB rootGiB reserveDefault minRootGiB=30

  totalGiB=$(( $(probe lsblk -bdno SIZE "$DISK" | head -n1) / 1073741824 ))
  logInfo "Disk is ${totalGiB}GiB"

  formConfirm "Reserve space for another OS?" "n" || return 0

  reserveDefault=$(( totalGiB / 2 ))

  while :; do
    formInputOpt RESERVE "Space to leave unallocated, in GiB" "$reserveDefault"
    RESERVE="${RESERVE:-$reserveDefault}"

    if ! [[ $RESERVE =~ ^[0-9]+$ ]] || (( RESERVE < 1 )); then
      logWarn "Enter a whole number of GiB"
      continue
    fi

    # 1 GiB ESP
    rootGiB=$(( totalGiB - 1 - SWAP - RESERVE ))
    if (( rootGiB < minRootGiB )); then
      logWarn "That leaves ${rootGiB}GiB for the system, and at least ${minRootGiB}GiB is needed"
      continue
    fi
    break
  done
}

# == dotfiles (optional) ==
gatherDotfiles() {
  formHeader "Dotfiles (optional)"
  DOTFILES=""

  formConfirm "Copy this host's dotfiles from a source?" "n" || return 0

  formChoose DOTFILES_METHOD "Method" "path" "git clone"

  if [[ $DOTFILES_METHOD == "path" ]]; then
    formFilter DOTFILES "Select directory" "$(listDirs)" "enter path" \
      || die "No directories found"
  else
    formInput DOTFILES "git repo to clone" "" "enter link"
  fi
}

# == summary ==
gatherSummary() {
  formHeader "Review Configuration"

  local i devices
  row() { printf '    %-14s %s\n' "$1" "$2"; }

  {
    [[ $REMOTE == true ]] && { row Target "$TARGET"; echo; }

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
    [[ $CLASS == "desktop" ]] && row Reserved "$( (( RESERVE > 0 )) && echo "${RESERVE}GiB" || echo none)"
    if [[ $EXISTING == true ]]; then
      row Keys "$([[ $PRESERVE == true ]] && echo kept || echo "regenerated (secrets.json starts over)")"
    else
      [[ $CLASS == "desktop" ]] && row Dotfiles "${DOTFILES:-skip}"
    fi
  } | gum style --border="rounded" --padding="1 2" --margin="1 0"
}

gather() {
  while :; do
    [[ $REMOTE == true ]] && gatherTarget

    gatherIdentity

    if [[ $EXISTING == true ]]; then
      loadHost || { logWarn "Pick a different hostname"; continue; }
      preserveIdentity

      # a layout change is the only reason to touch the disk settings of a host
      REDO_DISK=false
      if formConfirm "Redo the boot disk layout?" "n"; then
        REDO_DISK=true
        gatherDisk
        gatherSwap
        if [[ $CLASS == "desktop" ]]; then
          gatherLayout
        fi
      fi
    else
      gatherRole
      gatherUser
      gatherLocale
      gatherHardware
      gatherDisk
      gatherSwap

      if [[ $CLASS == "desktop" ]]; then
        gatherLayout
        gatherDotfiles
      fi
      gatherData
    fi

    gatherSummary

    if formConfirm "Is this correct?" "y"; then
      break
    fi

    logWarn "Redoing..."
  done
}

# ── generate keys ────────
generate() {
  formHeader "Generating keys"

  # == host keys ==
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

  # == user keys ==
  if [[ $PRESERVE == true ]]; then
    # the user key is itself a secret, so the host key is enough to recover it
    SOPS_AGE_KEY="$(ssh-to-age -private-key -i "$TEMP_DIR/ssh_host_ed25519_key")"
    export SOPS_AGE_KEY

    sops --decrypt "$FLAKE/hosts/$HOSTNAME/secrets.json" \
      | jq -j '.["user-privatekey"]' > "$TEMP_DIR/id_ed25519"
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

  # == syncthing: the device id is its certificate's ==
  if printf '%s\n' "${FEATURES[@]}" | grep -qx files; then
    local sync="$TEMP_DIR/syncthing"
    mkdir -p "$sync"
    if [[ -s $sync/cert.pem && -s $sync/key.pem && -n $SYNC_ID ]]; then
      logInfo "Kept the Syncthing id"
    else
      rm -f "$sync"/*
      SYNC_ID="$(syncthing generate --home "$sync" 2>&1 | grep -oE '[A-Z0-9]{7}(-[A-Z0-9]{7}){7}' | head -n1)"
      rm -f "$sync/config.xml"
      [[ -n $SYNC_ID ]] || die "Couldn't generate a Syncthing id"
      logInfo "Syncthing id: $SYNC_ID"
    fi
  fi
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
writeSecrets() {
  if [[ $PRESERVE == true ]]; then
    logInfo "Keeping the existing secrets"
    return 0
  fi

  [[ $EXISTING == true ]] && logWarn "New keys can't open the old secrets.json; it starts over"

  local hash pwd tailscale
  formPassword pwd "Login password for '$USERNAME'"
  hash="$(printf '%s' "$pwd" | mkpasswd -m sha-512 --stdin)"
  formPassword tailscale "Tailscale auth key (admin console: Settings → Keys)" false 1

  jq -n \
    --arg pw "$hash" \
    --rawfile key "$TEMP_DIR/id_ed25519" \
    --arg tailscale "$tailscale" \
    '{"user-password": $pw, "user-privatekey": $key, "tailscale-authkey": $tailscale}' \
    > "$FLAKE/hosts/$HOSTNAME/secrets.json"

  run sops --encrypt --in-place "$FLAKE/hosts/$HOSTNAME/secrets.json"
  git -C "$FLAKE" add --intent-to-add "hosts/$HOSTNAME/secrets.json"
  logInfo "Encrypted secrets"
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
      tomlSet "$file" disk.boot reserve "$RESERVE"
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
    echo "[locale]"
    echo "timezone = \"$TIMEZONE\""
    [[ $LOCALE != "en_US.UTF-8" ]] && echo "language = \"$LOCALE\""
    echo "keyboard = \"$KEYBOARD\""
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
    echo "reserve = $RESERVE"
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

  if [[ $EXISTING == true && -s $file ]] && ! formConfirm "Regenerate the hardware report?" "n"; then
    return 0
  fi

  while ! probe nix --extra-experimental-features "nix-command flakes" run nixpkgs#nixos-facter > "$file.tmp"; do
    rm -f "$file.tmp"
    if [[ $REMOTE == true ]] && ! isInstaller; then
      logWarn "The target can't run nixos-facter (no nix?)"
      formConfirm "Switch it into the installer in RAM now and try there? Nothing on its disks changes" "y" \
        || die "No hardware report; hosts/$HOSTNAME is written, nothing was wiped"
      kexecTarget
    else
      die "nixos-facter failed; hosts/$HOSTNAME is written, nothing was wiped"
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
      || die "Failed to clone git repository"
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
  writeSecrets
  writeHostToml
  writeFacter
  [[ $EXISTING != true ]] && writeDotfiles

  return 0
}

# ── what the questions don't cover ────────
# Both have to be in place before the install: disko formats disks only now, and one missing
# secret stops sops-nix from installing any of them at boot, the Tailscale key included.
complete() {
  formHeader "Before installing"
  logInfo "host.toml: feature tables ([gateway], …), and data disks ([disk.<label>]) for an existing host"
  logInfo "secrets.json: what the features need; the check names anything missing (a/b is {\"a\": {\"b\": …}})"

  local what
  while :; do
    what=$(gum choose --header="Edit, or check and go on" \
      "Check and continue" "Edit host.toml" "Edit secrets.json" "Show host.toml") || die "Cancelled"
    case "$what" in
      "Edit host.toml") "${EDITOR:-nano}" "$FLAKE/hosts/$HOSTNAME/host.toml" ;;
      "Edit secrets.json") sops "$FLAKE/hosts/$HOSTNAME/secrets.json" ;;
      "Show host.toml") gum pager < "$FLAKE/hosts/$HOSTNAME/host.toml" ;;
      "Check and continue")
        logInfo "Evaluating the configuration"
        if nixx eval --raw "$FLAKE#nixosConfigurations.$HOSTNAME.config.system.build.toplevel.drvPath" >/dev/null; then
          logInfo "It evaluates"
          break
        fi
        logWarn "It doesn't evaluate (above); fix it, or stop with Ctrl-C: hosts/$HOSTNAME is written, nothing was wiped"
        ;;
    esac
  done
}

# ── data disks ────────
EXTRA_DISKS=()

gatherWipe() {
  WIPE_EXTRA=false
  mapfile -t EXTRA_DISKS < <(tomlJson "$FLAKE/hosts/$HOSTNAME/host.toml" \
    | jq -r '.disk // {} | to_entries[] | select(.key != "boot") | .value.devices[]')
  (( ${#EXTRA_DISKS[@]} > 0 )) || return 0

  # the framework never wipes them: a disk that already has a filesystem is kept as it is
  formHeader "Data disks"
  printf '    %s\n' "${EXTRA_DISKS[@]}"
  logInfo "They are kept as they are, unless wiped here; empty ones are formatted either way"
  formConfirm "Wipe them? Everything on them is lost" "n" || return 0
  formTypeName "Type the host name to wipe the data disks too"
  WIPE_EXTRA=true
}

wipeExtra() {
  [[ $WIPE_EXTRA == true ]] || return 0
  local d
  for d in "${EXTRA_DISKS[@]}"; do
    # shellcheck disable=SC2016
    run probe sh -c 'for p in "$1"-part*; do [ -e "$p" ] && wipefs -a "$p"; done; wipefs -a "$1"' _ "$d"
  done
  logInfo "Wiped the data disks"
}

# == a FAT backup boot sector survives disko's wipefs: blkid still sees vfat, disko skips
# == mkfs.vfat and mounting /boot fails. Zero the start of the disk first.
zeroBootDisk() {
  probe umount -R /mnt 2>/dev/null || true
  run probe dd if=/dev/zero of="$DISK" bs=1M count=1100 conv=fsync status=none
}

# ── remote: into the installer in RAM ────────
kexecTarget() {
  local addr="${TARGET#*@}" i

  logWarn "Switching $TARGET into the installer; until the install, a reboot brings the old system back"
  ssh -o ControlPath="$TEMP_DIR/ssh-%C" -O exit "$TARGET" &>/dev/null || true
  # --flake is required even here; only the disko and install phases build anything
  nixx run --inputs-from "$FLAKE" nixpkgs#nixos-anywhere -- \
    --phases kexec --flake "$FLAKE#$HOSTNAME" --target-host "$TARGET"

  # the installer has a host key of its own
  ssh-keygen -R "$addr" -f "$TEMP_DIR/known_hosts" &>/dev/null || true
  for (( i = 0; i < 60; i++ )); do
    ssh "${SSH_OPTS[@]}" -o BatchMode=yes "$TARGET" true 2>/dev/null && break
    sleep 5
  done
  isInstaller || die "$TARGET didn't come back as the installer"
  logInfo "$TARGET runs the installer"
}

# == Everything the machine needs on disk before first boot ==
stageFiles() {
  local root="$1"
  local ssh="$root/persist/etc/ssh" home="$root/home/$USERNAME" sync="$TEMP_DIR/syncthing"

  install -d -m 755 "$ssh"
  install -m 644 "$TEMP_DIR/ssh_host_ed25519_key.pub" "$ssh/ssh_host_ed25519_key.pub"
  install -m 600 "$TEMP_DIR/ssh_host_ed25519_key" "$ssh/ssh_host_ed25519_key"

  install -d -m 700 "$home/.ssh"
  install -m 644 "$TEMP_DIR/id_ed25519.pub" "$home/.ssh/id_ed25519.pub"
  install -m 600 "$TEMP_DIR/id_ed25519" "$home/.ssh/id_ed25519"

  # the checkout, where axon.repo expects it; build output and caches stay behind
  install -d "$home/axon"
  tar -C "$FLAKE" --exclude=./result --exclude='./result-*' --exclude=./.direnv -cf - . \
    | tar -C "$home/axon" -xf -

  if [[ -s $sync/cert.pem ]]; then
    install -d -m 700 "$root/persist/var/lib/syncthing"
    install -m 600 "$sync/cert.pem" "$sync/key.pem" "$root/persist/var/lib/syncthing/"
  fi
}

# ── install ────────
installSystem() {
  formHeader "Installing"
  gatherWipe

  logWarn "$DISK on ${TARGET:-this machine} will be wiped"
  formTypeName "Type the host name to wipe and install"

  if [[ $REMOTE == true ]]; then
    installRemote
  else
    installLocal
  fi
}

# == install via nixos-install ==
installLocal() {
  local stage="$TEMP_DIR/stage"
  mkdir -p "$stage"
  stageFiles "$stage"

  zeroBootDisk
  wipeExtra
  run sudo disko --mode destroy,format,mount --yes-wipe-all-disks --flake "$FLAKE#$HOSTNAME"

  sudo cp -a "$stage/." /mnt/
  sudo chown -R 1000:100 "/mnt/home/$USERNAME"
  [[ -d /mnt/persist/var/lib/syncthing ]] && sudo chown -R 1000:100 /mnt/persist/var/lib/syncthing

  # the USB's tmpfs is too small for a first build
  sudo mkdir -p /mnt/tmp
  export TMPDIR=/mnt/tmp
  sudo systemctl set-environment TMPDIR=/mnt/tmp
  sudo systemctl restart nix-daemon

  logWarn "First install can take a while"
  sudo nixos-install --root /mnt --flake "$FLAKE#$HOSTNAME" --no-root-passwd

  logInfo "Installed $HOSTNAME"
  finish
  formConfirm "Reboot now?" "y" || die "Reboot manually"
  sudo reboot
}

# == Install via nixos-anywhere ==
installRemote() {
  local stage="$TEMP_DIR/stage"
  mkdir -p "$stage"
  stageFiles "$stage"

  isInstaller || kexecTarget
  zeroBootDisk
  wipeExtra

  logWarn "First install can take a while"
  nixx run --inputs-from "$FLAKE" nixpkgs#nixos-anywhere -- \
    --phases disko,install,reboot \
    --flake "$FLAKE#$HOSTNAME" \
    --extra-files "$stage" \
    --chown "/home/$USERNAME" 1000:100 \
    --chown /persist/var/lib/syncthing 1000:100 \
    --target-host "$TARGET"

  verifyRemote
  finish
}

# == verify the new system is reachable ==
verifyRemote() {
  local addr="${TARGET#*@}" ok=false i

  # Pin the key we generated, so this proves identity as well as reachability
  printf '%s %s\n' "$addr" "$HOST_KEY" > "$TEMP_DIR/known_hosts"

  logInfo "Waiting for $HOSTNAME to reboot"
  for (( i = 0; i < 60; i++ )); do
    if ssh -o StrictHostKeyChecking=yes -o ControlPath=none -o BatchMode=yes -o ConnectTimeout=10 \
        -o UserKnownHostsFile="$TEMP_DIR/known_hosts" "$USERNAME@$addr" true 2>/dev/null; then
      ok=true
      break
    fi
    sleep 5
  done

  if [[ $ok == true ]]; then
    logInfo "Host key verified, logged in as $USERNAME"
  else
    logWarn "Couldn't log in to $HOSTNAME as $USERNAME. It may still be booting, or cluster.toml"
    logWarn "[ssh] doesn't let this machine's key in yet; try ssh $USERNAME@$addr with the password"
  fi
}

finish() {
  {
    printf '%-10s %s\n' host "$HOSTNAME"
    [[ $REMOTE == true ]] && printf '%-10s %s\n' ssh "ssh $USERNAME@${TARGET#*@}"
    echo
    echo "Keep the new host, from this checkout:"
    echo "  git add -A && just commit \"feat($HOSTNAME): install\""
    echo "Then rebuild the other hosts, so they trust its keys and Syncthing id"
  } | gum style --border=rounded --padding="1 2" --margin="1 0"
  logWarn "If your known_hosts has an old key for the target: ssh-keygen -R ${TARGET#*@}"
}

# ── main ────────
main() {
  parseArgs "$@"

  # sudo is called where it's needed; as root, hosts/<name> and the repo copy would be root-owned
  if [[ $EUID -eq 0 ]]; then
    echo "install.sh: don't run as root; run it as your user, it calls sudo itself" >&2
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

  REGISTRY="$(nixx eval --json "$FLAKE#axon")" || die "The flake doesn't evaluate; fix that first"

  gather
  generate
  write
  complete
  installSystem
}

main "$@"
