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
| Services run native first; a container only where the native path fails or upstream ships only an image, its reason in its own row (Docker: rootful on servers for those services, rootless for the sandbox on every host with `dev`) | NixOS modules bring the user, state, hardening and database setup a container needs as glue; on unstable they lag upstream little. No account joins the docker group, which is root by another name, and published ports bind 127.0.0.1 only, as Docker's rules pass the firewall |
| No Watchtower or Portainer: container images change only through Renovate's pull requests | every image is pinned to a digest, so what runs is what the repository says, reviewed like any other change |
| JetBrains IDEs trust every project (`idea.trust.all.projects`) | chosen by the owner; there is no per-path setting |
| The KeeShare key in `hosts/tower/home/.config/keepassxc/keepassxc.ini` | KeeShare is unused; KeePassXC generates the key itself |
| Hardcoded domain in `home/` (Zen's pins and space routes), machine names only inside `hosts/<name>/` | `home/` is the owner's folder for all their hosts, so values the whole cluster shares may appear there; what belongs to one host goes in `hosts/<name>/home`; only the modules stay generic |
| Kanidm (gateway/accounts.nix) is the one login for every service that has a login; there is no other identity provider | one account and one passkey per person for everything |
| Tailnet routes get the gateway's login by default (`route.gate`); without login.nix's secrets they stay open, with a warning | the tailnet is the owner's alone, so a missing login is an extra lost, not a hole |
| Public routes, and git, docs and cache, never get the gateway's login (`route.gate`, gateway/login.nix) | the tunnel bypasses the gateway, so on a public route it would guard only the tailnet; git, nix and Paperless's apps reach the other three without a browser and can't follow a login |
| The tailnet logs in through Kanidm (gateway/tailnet-login.nix), which runs on a tailnet member | one login for everything; Tailscale needs Kanidm only to log in, so with key expiry off on the gateway an outage blocks new logins, not the network |
| Loki (monitoring/logs.nix) takes pushes and queries on the tailnet without a login | every host's Alloy pushes to it machine to machine; the tailnet is the owner's alone, and people read the logs in Grafana |
| Jellyfin keeps its own login, and Seerr, which logs in with Jellyfin accounts, follows it | TV and native apps can't do OpenID Connect; they sign in with Quick Connect |
| Vaultwarden's master password stays separate from Kanidm | it encrypts the vault; a login elsewhere can't replace it |
| n8n (automation/workflows.nix), unfree under its Sustainable Use License, keeps its own login behind the gate, and its workflow nodes may read its environment, where the API keys are | single sign-on is a paid feature; workflows are files in the checkout that take keys as `$env`, not credentials kept in the UI |
| People and their group memberships are made with the kanidm CLI, never in the repository | names and mail addresses of the family stay private |
| The second factor (passkey or TOTP) for `admins` is a Kanidm account policy set once by hand | Kanidm's provisioning has no account policies |

## Repository

| Decision | Why |
|---|---|
| Dotfiles are linked by our own `dotfiles-sync` (core/home.nix), not home-manager's file management | Nix never reads `home/`; files are live links into the checkout, edited in place, no rebuild |
| `dev` is pushed to Forgejo without review | daily work; the review sits at the merge into `stable` |
| core reads other hosts' `[forge] cache` key (core/nix.nix) | every host trusts the cluster's binary cache from its first build; the key is per host data, so it can't come from the feature lists alone |
| Only `stable` (merged, reviewed pull requests from `dev`) and `main` (its framework part, built by CI after every merge) reach the mirrors | the mirrors are the fallback when node1 is down, so they hold only reviewed code; Forgejo's push mirrors (filter `stable,main`) are set in its UI, not here |

## Secrets

| Decision | Why |
|---|---|
| `defaultSopsFormat = "yaml"` on `.json` files, `validateSopsFiles = false` | sops-nix's JSON reader rejects the nested keys these files use |
| `secrets.json` holds what the owner enters (`just secrets <host>`, install.sh) or lets install.sh generate, plus the user key install.sh makes; no module generates a value into it, and evaluation names what is missing | chosen: every secret is the owner's call, made once at install or by hand, never by the Nix config |

## Services

| Decision | Why |
|---|---|
| Kanidm, Jellyfin, Immich, Nextcloud, Vaultwarden and Home Assistant are public through the Cloudflare tunnel | family devices have no Tailscale; the risk under Cloudflare's terms (video streaming) is accepted |
| Home Assistant (family/hub.nix) runs as root in its container, against the rule of one user per container | the official image's process supervisor needs root; the NixOS module would run it as a user but can't install HACS, which the household cards come from |
| Home Assistant (family/hub.nix) has no Kanidm login (axon.sso), only its own accounts with TOTP | the only add-on (hass-oidc-auth) can't log in inside the Companion app (a code entered in the browser instead), its button fails on HA 2026.10+ (issue #446), and roles follow Kanidm only at first login |
| DNS records for public routes are made by hand at Cloudflare | not managed from this repo; a new public route needs its tunnel record (`cloudflared tunnel route dns`), a tailnet-only one none |
| Vaultwarden's admin page exists only while `secrets.json` holds `vaultwarden/admin-token` (passwords/vault.nix) | it is needed only to invite the family; off otherwise, so the public route has no admin login to attack |
| Radarr's and Sonarr's quality profiles and custom formats are a dotfile for Recyclarr (downloads/profiles.nix); indexers, download clients and root folders stay in the UIs | profiles are choices worth keeping in git; the rest holds credentials or rarely changes |
| qBittorrent's hardlinks into the library fail (it writes 0644) | btrfs shares the data anyway, so no space is lost |
| One service server per cluster for now: the gateway (gateway/proxy.nix) and Kanidm (gateway/accounts.nix) take only their own host's services; another server's routed services get no route or login, and a warning says so (server/headless.nix) | there is no contract yet for services on other hosts |
| Nextcloud is file storage only | no calendar, contacts or other apps |
| A tile's space use comes from its btrfs qgroup (metrics/spaces.nix), not from the app's own widget | apps show the whole volume's size, as btrfs limits don't change what statfs reports |
| Avahi only comes with printing | nothing else needs it since the `.local` names went |
| `onShutdown = "shutdown"` for libvirt | a saved state with virtiofs attached can't be restored |

## Backups and monitoring

| Decision | Why |
|---|---|
| No backup targets in any `secrets.json`; the backup feature only warns | waiting for a second server or a hosting service |
| The `local`/`proton` names of restic targets | renaming a target loses its history |
| No watchdog outside the cluster | the server stands next to its owner; a future second server would watch node1 |

## Desktop

| Decision | Why |
|---|---|
| fuzzel and mako only get colours, nothing more, and waybar runs its stock config (no dotfile) | a shell of its own (separate repo) will replace them |
| tower has no swap (`swap = 0`), so it can't hibernate, though the desktop class would resume from swap | chosen; it stays on or shuts down |
| Plain numbered niri workspaces, none bound to a purpose | the owner finds fixed workspaces restrictive |
| Zen's cookie allow list (browser/policies.nix), its extensions (browser/extensions.nix) and mods (browser/mods.nix) stay in Nix, though they are personal choices | Zen takes cookie exceptions and force-installed extensions only as enterprise policy, which Nix writes into its package; the zen-browser flake installs mods only from a Nix option |
| `kanshi` is installed on every desktop, though tower doesn't use it | for laptops and other hosts whose displays change; tower's fixed layout is in niri's own output config |
