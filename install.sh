#!/usr/bin/env bash
# install.sh: put a new machine into the repo and install it.
#
# Run from a checkout of this repo on the NixOS installer USB:
#   ./install.sh               install this machine
#   ./install.sh <ip>          install another machine over SSH (it runs the installer USB too;
#                              set a root password there with `passwd` first)
#
# It asks a few questions, then writes hosts/<name>/ (host.toml, facter.json, secrets.json),
# adds the machine's keys to .sops.yaml, lets you add what the questions don't cover (extra
# disks, the features' tables and secrets), checks that the config evaluates, and only then
# wipes the chosen disk.
set -euo pipefail

# the tools come from nixpkgs; re-run inside a shell that has them
tools=(git jq yq-go sops ssh-to-age mkpasswd openssh syncthing disko nixos-anywhere sshpass)
if [ -z "${AXON_INSTALL_SHELL:-}" ]; then
  export AXON_INSTALL_SHELL=1
  exec nix --extra-experimental-features "nix-command flakes" shell "${tools[@]/#/nixpkgs#}" -c bash "$0" "$@"
fi

repo=$(cd "$(dirname "$0")" && pwd)
cd "$repo"
# sudo is called where it's needed; as root, hosts/<name> and the repo copy would be root-owned
if [ "$EUID" -eq 0 ]; then
  echo "install.sh: don't run as root; run it as your user, it calls sudo itself" >&2
  exit 1
fi
target=${1:-}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

# ask VAR "question" [default]
ask() {
  local reply
  read -rp "$2${3:+ [$3]}: " reply
  printf -v "$1" '%s' "${reply:-${3:-}}"
  [ -n "${!1}" ] || die "$2 is required"
}

# ask_secret VAR "question"
ask_secret() {
  local reply again
  read -rsp "$2: " reply; echo
  read -rsp "again: " again; echo
  [ "$reply" = "$again" ] || die "the two entries differ"
  [ -n "$reply" ] || die "$2 is required"
  printf -v "$1" '%s' "$reply"
}

# choose VAR "question" option...
choose() {
  local var=$1 question=$2 option
  shift 2
  echo "$question"
  select option in "$@"; do
    [ -n "$option" ] && { printf -v "$var" '%s' "$option"; return; }
  done
}

# run on the machine being installed
on_target() {
  if [ -n "$target" ]; then
    sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@$target" "$@"
  else
    sudo "$@"
  fi
}

flake_eval() { nix --extra-experimental-features "nix-command flakes" eval "$@"; }

if [ -n "$target" ]; then
  ask_secret SSHPASS "root password of the installer on $target (set with passwd there)"
  export SSHPASS
  on_target true || die "can't log in to root@$target"
fi

# ── what this machine is ────────
say "machine"
ask name "host name"
case "$name" in _* | *[!a-z0-9-]*) die "host names are lowercase letters, digits and dashes" ;; esac
if [ -e "hosts/$name" ]; then
  ask overwrite "hosts/$name exists; replace it (new keys, old secrets lost)? yes/no" no
  [ "$overwrite" = yes ] || die "stopped"
fi

registry=$(flake_eval --json .#axon)
mapfile -t classes < <(jq -r '.classes | keys[]' <<<"$registry")
choose class "class:" "${classes[@]}"

mapfile -t available < <(jq -r --arg c "$class" '.features | to_entries[] | select(.value.classes | index($c)) | "\(.key)\t\(.value.description)"' <<<"$registry")
echo "features (numbers separated by spaces, empty for none):"
for i in "${!available[@]}"; do printf '  %d) %s\n' $((i + 1)) "${available[$i]//$'\t'/ – }"; done
read -rp "> " picks
features=()
for n in $picks; do
  [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#available[@]} ] || die "no feature number $n"
  features+=("${available[$((n - 1))]%%$'\t'*}")
done

say "user"
ask user "login name" gldn
ask email "email (git identity, certificate contact)"
ask_secret password "login password"
ask tailscale "Tailscale auth key (admin console: Settings → Keys)"

say "locale"
ask timezone "time zone" Europe/Berlin
ask keyboard "keyboard layout" us

# ── disk ────────
say "boot disk (it will be wiped)"
mapfile -t disks < <(on_target lsblk -dnpo NAME,SIZE,MODEL,TYPE | awk '$NF == "disk" {$NF=""; print}')
[ ${#disks[@]} -gt 0 ] || die "no disks found"
choose disk "disk:" "${disks[@]}"
disk=${disk%% *}
# by-id survives disks being renumbered
byid=$(on_target ls -l /dev/disk/by-id/ | awk -v d="$(basename "$disk")" \
  '$NF ~ ("/" d "$") && $9 !~ /-part|^wwn-/ {print "/dev/disk/by-id/" $9; exit}' || true)
device=${byid:-$disk}

ram=$(on_target awk '/MemTotal/ {print int($2 / 1048576 + 0.5)}' /proc/meminfo)
if [ "$class" = desktop ]; then swapdefault=$((ram + 2)); else swapdefault=8; fi
ask swap "swap in GiB (RAM + 2 allows hibernation, 0 for none)" "$swapdefault"
ask reserve "GiB to leave free at the end of the disk (for Windows)" 0

# ── keys ────────
say "keys"
mkdir -p "$work/root/persist/etc/ssh" "$work/root/home/$user/.ssh"
ssh-keygen -q -t ed25519 -N "" -C "root@$name" -f "$work/root/persist/etc/ssh/ssh_host_ed25519_key"
ssh-keygen -q -t ed25519 -N "" -C "$user@$name" -f "$work/root/home/$user/.ssh/id_ed25519"
hostkey=$(cat "$work/root/persist/etc/ssh/ssh_host_ed25519_key.pub")
userkey=$(cat "$work/root/home/$user/.ssh/id_ed25519.pub")
hostage=$(ssh-to-age <<<"$hostkey")
userage=$(ssh-to-age <<<"$userkey")

syncid=""
if printf '%s\n' "${features[@]}" | grep -qx files; then
  # the device id is the certificate's; put the certificate where Syncthing will find it
  mkdir -p "$work/root/persist/var/lib/syncthing"
  syncid=$(syncthing generate --home "$work/root/persist/var/lib/syncthing" 2>&1 | grep -oE '[A-Z0-9]{7}(-[A-Z0-9]{7}){7}' | head -n1)
  rm -f "$work/root/persist/var/lib/syncthing/config.xml"
  [ -n "$syncid" ] || die "couldn't generate a Syncthing id"
fi

# ── files ────────
say "writing hosts/$name"
rm -rf "hosts/$name"
mkdir -p "hosts/$name"
state=$(flake_eval --raw --inputs-from . nixpkgs#lib.trivial.release)

{
  echo "[host]"
  echo "class = \"$class\""
  if [ ${#features[@]} -gt 0 ]; then
    printf 'features = [%s]\n' "$(printf '"%s", ' "${features[@]}" | sed 's/, $//')"
  else
    echo "features = []"
  fi
  echo "state = \"$state\" # written once at install, never changed"
  echo "key = \"$hostkey\""
  echo
  echo "[user]"
  echo "name = \"$user\""
  echo "email = \"$email\""
  echo "key = \"$userkey\""
  echo
  echo "[locale]"
  echo "timezone = \"$timezone\""
  echo "keyboard = \"$keyboard\""
  echo
  echo "[disk.boot]"
  echo "devices = [\"$device\"]"
  echo "swap = $swap"
  echo "reserve = $reserve"
  if [ -n "$syncid" ]; then
    echo
    echo "[sync]"
    echo "id = \"$syncid\""
  fi
} >"hosts/$name/host.toml"

# the machine's two keys may decrypt its secrets; nothing else
[ -f .sops.yaml ] || echo "creation_rules: []" >.sops.yaml
RULE="hosts/$name/secrets\\.json\$" USER_AGE="$userage" HOST_AGE="$hostage" yq -i '
  .creation_rules = ([.creation_rules[] | select(.path_regex != strenv(RULE))]
    + [{"path_regex": strenv(RULE), "key_groups": [{"age": [strenv(USER_AGE), strenv(HOST_AGE)]}]}])
' .sops.yaml

jq -n \
  --arg password "$(mkpasswd -m sha-512 --stdin <<<"$password")" \
  --rawfile key "$work/root/home/$user/.ssh/id_ed25519" \
  --arg tailscale "$tailscale" \
  '{"user-password": $password, "user-privatekey": $key, "tailscale-authkey": $tailscale}' \
  >"hosts/$name/secrets.json"
sops --encrypt --in-place "hosts/$name/secrets.json"

# ── hardware ────────
say "hardware report"
if [ -n "$target" ]; then
  on_target nix --extra-experimental-features "nix-command flakes" run nixpkgs#nixos-facter >"hosts/$name/facter.json"
else
  sudo nix --extra-experimental-features "nix-command flakes" run nixpkgs#nixos-facter >"hosts/$name/facter.json"
fi

git add --intent-to-add "hosts/$name" .sops.yaml

# ── what the questions don't cover ────────
# Both have to be in place before the install: disko formats disks only now, and one missing
# secret stops sops-nix from installing any of them at boot, the Tailscale key included.
say "before installing"
echo "  host.toml     extra disks ([disk.<label>]) and feature tables ([gateway], …)"
echo "  secrets.json  what the features need; the check below names anything missing"
# the new user key opens secrets.json; it goes with $work when this script ends
SOPS_AGE_KEY=$(ssh-to-age -private-key -i "$work/root/home/$user/.ssh/id_ed25519")
export SOPS_AGE_KEY
edit() {
  local what
  while :; do
    read -rp "edit [h]ost.toml, [s]ecrets.json, or [c]ontinue: " what
    case "$what" in
      h) "${EDITOR:-nano}" "hosts/$name/host.toml" ;;
      s) sops "hosts/$name/secrets.json" ;;
      c) return ;;
    esac
  done
}
edit

# ── check before anything is wiped ────────
say "evaluating the new configuration"
until flake_eval --raw ".#nixosConfigurations.$name.config.system.build.toplevel.drvPath" >/dev/null; do
  echo "the configuration doesn't evaluate (above); fix it here, or stop with Ctrl-C: hosts/$name is written, nothing was wiped"
  edit
done

echo
echo "  host     $name ($class: ${features[*]:-no features})"
echo "  user     $user <$email>"
echo "  disk     $device, swap ${swap}G, ${reserve}G left free"
echo "  where    ${target:-this machine}"
ask go "wipe $device and install? type the host name to go on"
[ "$go" = "$name" ] || die "stopped; hosts/$name is written, nothing was wiped"

# ── install ────────
# the user's key and the repo go to /home; the host key and Syncthing's certificate to /persist
cp -r "$repo" "$work/root/home/$user/axon"
rm -rf "$work/root/home/$user/axon/result"

# a FAT backup boot sector survives disko's wipefs: blkid still sees vfat, disko skips
# mkfs.vfat and mounting /boot fails. Zero the start of the disk first.
on_target umount -R /mnt 2>/dev/null || true
on_target dd if=/dev/zero of="$device" bs=1M count=1100 conv=fsync status=none

if [ -n "$target" ]; then
  nixos-anywhere --flake ".#$name" --env-password \
    --extra-files "$work/root" \
    --chown "/home/$user" 1000:100 \
    --chown /persist/var/lib/syncthing 1000:100 \
    --target-host "root@$target"
else
  sudo disko --mode destroy,format,mount --yes-wipe-all-disks --flake ".#$name"
  sudo cp -a "$work/root/." /mnt/
  sudo chown -R 1000:100 "/mnt/home/$user"
  [ -d /mnt/persist/var/lib/syncthing ] && sudo chown -R 1000:100 /mnt/persist/var/lib/syncthing
  sudo nixos-install --flake ".#$name" --no-root-passwd
fi

say "done"
cat <<NEXT
  Reboot into $name. Then, on it:
    cd ~/axon && git add -A && just commit "feat($name): install"   # keep the new host
    just secrets                                                  # change secrets later
NEXT
