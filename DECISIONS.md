# Decisions

Choices that look like mistakes or gaps but are deliberate. Don't "fix" them, and don't flag them
in a review. A choice that the comment on its own lines explains stays in that comment; this file
holds the ones that span several files or are about something deliberately missing.

To change one, change it here in the same commit, with the new reason.

## Security and access

| Decision | Why |
|---|---|
| `PasswordAuthentication = true` | a lost key must not lock you out of a machine you can't walk to |
| No LUKS | chosen; hibernation into a plain swap partition |
| podman only, `docker` as an alias | rootless by design; a docker group is root-equivalent |
| JetBrains IDEs trust every project (`idea.trust.all.projects`) | chosen by the owner; there is no per-path setting |
| The KeeShare key in `hosts/tower/home/.config/keepassxc/keepassxc.ini` | KeeShare is unused; KeePassXC generates the key itself |
| Hardcoded domain, user and machine names inside `hosts/<name>/` | that folder belongs to exactly one host; only modules and `home/` must stay generic |

## Repository

| Decision | Why |
|---|---|
| `dev` is pushed to Forgejo without review | daily work; the review sits at the merge into `stable` |
| Only `stable` (merged, reviewed pull requests from `dev`) and `main` (its framework part, built by CI after every merge) reach the mirrors | the mirrors are the fallback when node1 is down, so they hold only reviewed code; Forgejo's push mirrors (filter `stable,main`) are set in its UI, not here |

## Secrets

| Decision | Why |
|---|---|
| `defaultSopsFormat = "yaml"` on `.json` files, `validateSopsFiles = false` | sops-nix's JSON reader rejects the nested keys these files use |

## Services

| Decision | Why |
|---|---|
| Jellyfin, Seerr, Immich and Nextcloud are public through the Cloudflare tunnel | family devices have no Tailscale; the risk under Cloudflare's terms (video streaming) is accepted |
| DNS records are made by hand at Cloudflare | not managed from this repo; a new route needs its record added there |
| Radarr, Sonarr and Prowlarr settings (quality profiles, indexers) live in their UIs, not in Nix | they are per-host choices |
| qBittorrent's hardlinks into the library fail (it writes 0644) | btrfs shares the data anyway, so no space is lost |
| Nextcloud is file storage only | no calendar, contacts or other apps |
| Space usage is not on the start page | quotas are set per user in the apps; apps show the whole volume's size, as btrfs limits don't change what statfs reports |
| Avahi only comes with printing | nothing else needs it since the `.local` names went |
| `onShutdown = "shutdown"` for libvirt | a saved state with virtiofs attached can't be restored |

## Backups and monitoring

| Decision | Why |
|---|---|
| No backup targets in any `secrets.json`; the backup feature only warns | waiting for a second server or a hosting service |
| The `local`/`proton` names of restic targets | renaming a target loses its history |
| No watchdog outside the cluster | a future second server would watch node1 |
| Failure mails have a plain layout: the facts, then the log | the owner reads the log; no summary box on top |

## Desktop

| Decision | Why |
|---|---|
| Dotfiles are linked by our own `dotfiles-sync` (core/home.nix), not home-manager's file management | Nix never reads `home/`; files are live links into the checkout, edited in place, no rebuild |
| waybar, fuzzel and mako only get colours, nothing more | a shell of its own (separate repo) will replace them |
| Plain numbered niri workspaces, none bound to a purpose | the owner finds fixed workspaces restrictive |
