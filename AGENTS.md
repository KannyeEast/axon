# AGENTS.md

Instructions for an assistant working in this repository.

## Principle

Opinionated but modular: the framework (`modules/`) is a toolset that serves any owner and any
machine, and personal choices stay out of it. They live in dotfiles, on desktops and servers
alike: whatever a program or service can read from a file is a file in `home/` or
`hosts/<name>/home`, not Nix and not a setting kept in a UI. `host.toml` describes the host and
nothing else.

Every file has a kind, and every kind has one shape ([Structure](#structure)). A module states
facts about its service and core turns them into wiring; a module never works around another
module of this repository. When it would have to, a contract is missing a piece, and the fix
goes into core.

## Roles

This repository is a NixOS configuration built on a small framework (axon) that lives in it. Two
assistants work on it with the same knowledge (this file and [DECISIONS.md](DECISIONS.md)) and
different jobs. Started by CI on a pull request, you are the reviewer; otherwise the author.

**Author.** You change the configuration with its owner, in a conversation. Explain, then act:
say what you found and what you intend to change before editing. Stop for confirmation on
anything beyond a single obvious fix, and don't bundle unrequested changes. Say what you verified
and what you didn't. Asked to fix the review, read its open findings
(`bash .forgejo/findings.sh`) and fix each one, or say why not.

**Reviewer.** You check a pull request and change nothing. Follow
[.forgejo/review.md](.forgejo/review.md). Every finding names the rule it breaks, why that
matters here, and the concrete fix. A choice recorded in DECISIONS.md is not a finding.

## Layout

```
flake.nix            inputs; outputs = every .nix under modules/ (import-tree)
cluster.toml         the cluster's domain; relations between machines: [ssh], [sync], [external]; the repo's remotes: [repo]
tailnet.hujson       the tailnet's access rules, applied by CI after a merge into stable
DECISIONS.md         deliberate choices that look like mistakes; never "fixed" or flagged
install.sh           the installer: asks, writes hosts/<name>/, installs from a USB stick or remotely
justfile             the owner's commands: switch, deploy, check, fmt, docs, secrets, pr
.forgejo/            CI: check and review on pull requests (merged without findings), main published from stable; the reviewer's guide;
                     findings.sh, the latest review's open findings for the author
hosts/<name>/        host.toml, facter.json, secrets.json (sops), optional home/
hosts/_<name>/       kept for reference, never built
home/                dotfiles every host uses (the terminal); hosts/<name>/home wins per file
modules/framework/   the registry, host discovery, docs output
modules/core/        every host
modules/classes/     exactly one per host: desktop, server
modules/features/    opt-in areas, one folder each; a host lists the ones it subscribes to
```

A file under `modules/<kind>/<name>/` declares into `flake.modules.{nixos,homeManager}.<name>`.
Never import another `.nix` file by path; import-tree already loads everything. A file or folder
starting with `_` is ignored (templates, data).

## How a host is built

`modules/framework/hosts.nix` reads `host.toml`, picks `core` + the class + the features, checks
the TOML against the schema pieces those bundles own (`axon.schema.<bundle>`), and builds the
system. Modules read host data from `config.axon.<table>` (`host`, `user`, `locale`, `disk`,
`sync`, `gateway`, …) and other hosts from `config.axon.cluster.hosts`. No specialArgs.

## Where a thing goes

| It is | It goes |
|---|---|
| The same on every host | set it, in the module |
| Different per host, detectable | derived (facter): a read-only `axon.<name>` with a `default` |
| Different per host, a choice about the machine | a field in `host.toml`, typed in `axon.schema.<bundle>` |
| A relation between machines | `cluster.toml` |
| A setting a program or service reads from a file | a dotfile: `home/` if every host uses it, else `hosts/<name>/home` |
| Static data a service reads (a dashboard, rules, a template, a script) | a `_file` next to its module; Nix passes in only what depends on the cluster |
| Something other modules on the host need to know about a service | its `axon.services.<name>` entry, or the contract for it |
| Something other hosts need to know | the feature lists in `cluster.hosts`, the only cross-host data |
| A different behaviour | a feature, never an option |

**Core, class or feature?** Core: a machine can't boot, log in or be managed from this repo
without it. Class: the barest machine of that class needs it. Feature: you can name a host of
that class that wouldn't want it.

**A feature is an area, not a program.** A new service goes into the feature whose area it is.
Split a feature only when a named host wants one part and not the other.

## Structure

### A feature

```
modules/features/<area>/
  feature.nix      its registry entry, nothing else
  <job>.nix        one service or one app per file, named for what it does (passwords.nix, not keepassxc.nix)
  _<name>.<ext>    data and scripts its modules read
hosts/<name>/home/.config/<program>/    the settings its programs read
hosts/<name>/secrets.json               its secrets, <area>/<name>
hosts/<name>/host.toml                  a table only where the feature owns one
```

One service or app per file, with its helpers. Several apps share a file only while they are the
same shape and none needs an exception; the first exception gets its own file. A file serves one
class: a feature for both has one file per side.

### Every module file

```nix
# header: see the file's kind below
{ lib, ... }:                       # only what the file uses; no function when it uses nothing
let
  inherit (lib) mkOption types;     # only in a file that declares options; nothing else is inherited
in
{
  axon.schema.<bundle> = { … };     # 1 the host.toml table this file owns, if any

  flake.modules.nixos.<bundle> =    # 2
    { config, pkgs, ... }:
    let
      inherit (config.axon) …;      # contracts and host data, alphabetical
      inherit (config.axon.services.<name>) route;
      port = 1234;                  # then constants: ports, paths
      …                             # then what is derived from them
    in
    lib.mkIf <gate> {               # one gate for the whole file: the class, or the volume or contract it can't run without
      <slots>
    };

  flake.modules.homeManager.<bundle> = { … };   # 3
}
```

- `lib` comes from the outer function, never from the module's own arguments. Modules write
  `lib.<function>`.
- The body is made of **slots**, in the order of the file's kind. A slot that doesn't apply is
  left out, never moved. A file with three or more slots opens each with a ruler:
  `# ── service ────────`.
- Inside a slot: the main definition first, then what adjusts it. A line that isn't obvious
  carries its reason as a comment above it.

### Slots

One vocabulary for all kinds, always in this order:

| Slot | Holds |
|---|---|
| `contract` | `options.axon.<name>`: the contract a core file declares |
| `settings` | plain NixOS settings of a core or class file |
| `service` | `services.<name>` through its NixOS module, or its `virtualisation.oci-containers` entry |
| `program` | packages and `programs.<name>` |
| `units` | `systemd.services`, `systemd.timers`: changes to the service's units, then the file's own units |
| `session` | `systemd.user.services`: what starts with the desktop session |
| `system` | what only Nix can wire for a desktop program: D-Bus, udev, portals, PAM, dconf defaults |
| `secrets` | every `sops.secrets` and `sops.templates` entry the file reads |
| `login` | `axon.sso.clients.<name>` |
| `data` | `axon.databases`, `axon.persist…`, `axon.spaces` |
| `contracts` | what the file adds to other contracts (`axon.overlay`, `axon.vpn.confined`, `axon.links`, `axon.browser`), or the value it produces (`axon.mail`, `axon.sso.provider`, `axon.routed`, `axon.gated`) |
| `registration` | `axon.services.<name>`: route, tile, units, logs, backup |
| `checks` | `warnings`, `assertions` |

### Kinds

**Registry entry** (`feature.nix`, `class.nix`). No header, no function, one attribute set:
`description`, `classes`, and `requires` where the feature has a hard need.

**Core contract** (`modules/core/<contract>.nix`, named after the contract).
Slots: `contract`, `settings`, `units`, `data`, `checks`.

```nix
# Contract: axon.<name>. <What it is.> <Who produces it, who consumes it, and what a consumer
# does when it is empty or null.>
```

Every option has a `description`. A derived value is read-only with a `default` and a
`defaultText`. A contract needs two consumers in different features, or a realistic swap; else
it lives in its feature. Core names no feature and holds no provider's format.

**Core or class settings** (`boot.nix`, `locale.nix`, `fonts.nix`).
Slots: `settings`, `units`, `data`, `checks`. Header: one or two lines saying what the file does.

**Server service.**
Slots: `service`, `units`, `secrets`, `login`, `data`, `contracts`, `registration`, `checks`.

```nix
# <Program> at <name>.<domain>: <what it is for>.
# Reach: <tailnet | public>, <the gateway's login | its own login | no login>.
# In its UI only: <what>, <how it is backed up>.
# By hand: <the step after install>.            (left out when there is none)
```

**Desktop program** (in a class or a feature).
Slots: `program`, `session`, `system`, `secrets`, `data`, `contracts`, `checks`.

```nix
# <Program>: <what it is for>.
# Settings: <its dotfiles>.
# Windows: <app id>. Key: <bind>.               (for a GUI program)
```

Adding one, in the same change: the package in its area's file; a `session` unit if it runs in
the background; its settings as a dotfile; file types in `mimeapps.list`; its key in `apps.kdl`
(a feature's) or `bindings.kdl` (the class's); and its windows. Find the Wayland app id (the
`.desktop` file's name or `StartupWMClass`, or the application id in its source) and decide per
window: main windows tile; dialogs with a parent window and fixed-height windows float by
themselves in niri; small tool windows, pickers and popups without a parent get an
`open-floating` rule in each desktop's `hosts/<name>/home/.config/niri/windows.kdl`.

**Producer or helper** (a file that produces a contract value, or holds only own units:
`mail.nix`, `vpn/check.nix`). Slots as they apply, in the order of the table. Header: what it
does, in one or two lines.

**Data file** (`_<name>.<ext>`). Its first comment names the module that reads it. Sections get
the ruler in the file's comment style.

### Own units and scripts

Only when nothing existing fits (Rules: use what exists). Then:

- Shell is `pkgs.writeShellApplication`. Anything longer than a screen, or not shell, is a
  `_<name>.<ext>` data file.
- The unit sits in the `units` slot of the service it serves and is listed in that service's
  `units`. A unit that serves none gets its own file and its own `axon.services` entry.
- Its errors carry a level: a `<3>` prefix or the word `error`.
- A comment on the unit names the option or package that was looked at and why it didn't fit.

### Dotfiles

- Nix never reads `home/` or `hosts/<name>/home`, and modules don't write dotfiles. Nix installs
  programs and loads what needs a store path; settings live in dotfiles. They are the owner's
  files, independent of the features, and may spell out a default.
- `home/` holds only what every host uses (the terminal: zsh, nvim, tmux, starship, direnv,
  claude, ccstatusline) and must not assume a feature is there. Everything else is the host's own
  in `hosts/<name>/home`, copied between hosts that share it.
- A program's files sit where the program looks for them: `.config/<program>/`.
- A file with several sections separates them with a ruler: `# ── name ────────` (`--` in Lua,
  `//` in KDL and JavaScript).
- A desktop's niri folder has one file per concern: `config.kdl` (includes the rest), `input.kdl`,
  `output.kdl`, `layout.kdl`, `colors.kdl`, `startup.kdl`, `bindings.kdl`, `apps.kdl`,
  `windows.kdl`.

### host.toml, cluster.toml, secrets.json

- `host.toml`: core's tables first, in the order `[host]`, `[user]`, `[locale]`, `[hardware]`,
  `[disk.*]`, `[limits]`; then each feature's table, in the order of the features. `features` is
  alphabetical. A field equal to its schema default is left out.
- A table becomes `config.axon.<table>`, so its name must not be a core option's (`mail`,
  `links`, `secrets`, `volumes`).
- A new field is an option in `axon.schema.<bundle>`, in the file that reads it, with a type, a
  default where one makes sense, and a description.
- `secrets.json`: every key is `<area>/<name>`, never flat. The area is the service or account
  the secret belongs to (`user`, `tailscale`, `kanidm`, `sso`, `mail`, `forge`), the name says
  what it is, in kebab-case. A service's API key is `<its axon.services name>/api-key`.

## One way per need

Modules that produce the same result do it the same way. A shared helper only when many modules
use it.

| Need | The way |
|---|---|
| A port | one `port` in the `let`, used by the service and by `route.port`; written out even when it is the default |
| Listening | on `127.0.0.1` or inside the VPN namespace; the gateway proxies. A port for other machines only through `axon.overlay`, never `networking.firewall` directly |
| A route | `axon.services.<name>.route`. The gateway's login stands in front of every tailnet route (`gate`, off only for clients that can't follow a browser login); the tunnel bypasses it, so `public = true` only for a service with its own login |
| The name a service answers to | `route.name` |
| Its own address in its settings | `route.origin` |
| An address registered elsewhere (redirects) | `route.url` |
| Calling it from the same host | `route.internal` |
| Is the gateway's login in front of it | `route.gated` |
| A login | `axon.sso.clients.<name>` with `service`, which fills its name, icon and landing; the service logs in there when `axon.sso.provider` isn't null and keeps its own login otherwise; `client.placeholder` puts its secret into a sops template, `client.groupClaim` is its group as the provider's groups claim lists it |
| Mail | `axon.mail`; the service works when it is null. The sender is `<service name>@<domain>` |
| A secret the file can't do without | declare its `sops.secrets`; evaluation lists what is missing. Every file declares each secret it reads |
| An extra that switches on with its secret | `config.axon.hasSecret "<area>/<name>"`; without the secret the extra is off, with one warning naming the secret |
| A service's API key | `axon.services.<name>.apiKey`, the secret `<name>/api-key`; `dashboard.key` when the start page's widget needs it |
| A secret into a NixOS service | what its module offers, in this order: a `…File` option, `LoadCredential`, a sops template as environment file |
| A secret into an own unit or container | `LoadCredential`; for a container a sops template in `environmentFiles`, never `environment` |
| A Postgres database | `axon.databases` and the module's own `createLocally` |
| State, a static user with `StateDirectory` | the persist entry is the plain path. A mode only through `StateDirectoryMode`, and only where it differs from upstream |
| State, `DynamicUser` | persist `/var/lib/private/<name>` |
| A static user where the module gives none (a container that keeps data, a service taken off `DynamicUser`) | its own system user with a fixed id from 400 up, declared next to it; NixOS refuses a duplicate id |
| State, a subfolder upstream creates with tmpfiles | its own persist entry |
| Which persist list | a service's state: `axon.persist.state.directories` (the state volume where a host has one); the system's own: `axon.persist.directories` (the boot disk). In the file that creates the state |
| User data (files, photos, documents) | its own `axon.spaces` entry, with `units` naming every unit that uses it |
| Writing to a volume | `RequiresMountsFor` on the unit: data disks mount with `nofail`, and without it the unit writes to root |
| Backup | `backup.paths` for what can't be rebuilt, `exclude` for what can; a database through its dump or export, never its live files |
| A dump or export a backup reads | `"${config.axon.dumps}/<name>"` |
| The start page | a `dashboard` entry: name, group, icon, a widget where Homepage has one, and the `space` its tile shows |
| Logs | every unit of the file in the service's `units`; a program that prints no level gets a log-format or log-level setting; entries spanning lines set `logStart` |
| Traffic that must not leave in the open | `axon.vpn.confined` |
| A container | only where DECISIONS gives its reason. `virtualisation.oci-containers`, the image on one `image = "<registry>/<name>:<tag>@sha256:<digest>"` line, ports on `127.0.0.1`, every host path it writes persisted |
| Something on another host | `config.axon.hostsWith "<feature>"`, from the feature lists in `config.axon.cluster.hosts`; never a host name |
| A program that runs with the desktop session | a `systemd.user.services` unit on `graphical-session.target`. The shell's own parts (bar, wallpaper, idle) start from the owner's `startup.kdl` |
| Glue between services | an n8n workflow in `hosts/<name>/home/.config/n8n/workflows`; systemd only for what DECISIONS lists |

## Rules

- **Use what exists before building it.** Before a custom script, wrapper or option, look for
  what already does it: a setting of the NixOS module or the program itself, a package or plugin
  in nixpkgs, a common add-on (the program's docs, its issue tracker, the web). Write your own only
  when nothing fits, and say in your reply what you looked at.
- **A dependency is a hard need or an extra.** A hard need is `requires` or an assertion. Anything
  that can work without the other piece must, and the piece only adds to it; never fail silently.
  Features read contracts, not each other's options or names. Producers set a contract
  unconditionally; consumers handle an empty set or null.
- **Contracts are declared in core**: `axon.services` (routes, backup paths), `axon.persist`,
  `axon.volumes`, `axon.spaces` (a service's own subvolume, capped by `[limits]`), `axon.mail`,
  `axon.sso` (single sign-on), `axon.vpn`, `axon.overlay`, `axon.browser`, `axon.links` (admin
  links on the start page), `axon.databases` (Postgres databases, dumped nightly). Derived values
  core exposes: `axon.domain`, `axon.routed`, `axon.gated`, `axon.routes`, `axon.secrets`, `axon.hasSecret`,
  `axon.dumps`, `axon.hostsWith`, `axon.dotfiles`, `axon.remotes`, `axon.home`, `axon.repo`,
  `axon.laptop`, `axon.nvidia`.
- **Only what changes something.** Don't restate an upstream default (read the module's source),
  and don't add an option nothing sets, a helper with one caller or a package nothing runs. The
  framework (`modules/`, published on `main`) serves any machine, not only these hosts: what a
  host you can describe (another architecture, disk layout or class) needs is not dead weight.
- **A change takes its references with it.** Renaming, replacing or removing something (a
  program, a unit, a script, an option, an app id, a path) means searching the whole repository
  for it, `home/` and `hosts/*/home` included, and updating every place in the same change.
- **Formatting**: `nix fmt`. Never align `=` or values with extra spaces, in any file type.
- **Comments are short and few.** They describe the code as it is: never history, rejected
  alternatives or reasoning from a conversation, which belong in the commit message.
  - *Header*: the lines of the file's kind and nothing else, each one line. At most four for a
    server service, three for a desktop program or a core contract, two for any other file, one
    for a data file.
  - *Inline*: one line above the line it explains, for what a reader can't see from the code: a
    reason, a quirk, a non-obvious value. Two lines only for a workaround, which says what breaks
    without it. A few words after a value, on its line, may label it.
  - *Never*: what the code already says (an option's name, what a call does), how the pieces fit
    together, an example the code shows, a comment on a `let` name or an option that has a
    `description`.
  - A reason that needs more than two lines is a row in DECISIONS.md.
  - An option's `description` is one sentence.
- **Strings a person reads are terse.** Errors read `<file or option>: <what is wrong>` and say
  what to do where possible. Alert texts, warnings and descriptions say what it is in as few
  words as possible, and nothing the reader already knows (the alert's name, how often it comes,
  what follows from it).
- **Decisions are written down.** A deliberate choice that the comment on its lines explains
  stays in that comment. One that spans files or is about something deliberately missing goes
  into DECISIONS.md with its reason, in the same commit.
- **Flake inputs** follow `nixpkgs` (and `home-manager`) where they take them.
- **A JetBrains plugin** is checked for a cast to `JarURLConnection` before it is added
  (`unzip -p <plugin jars> | grep -ac java/net/JarURLConnection` must print 0): such plugins
  break every file lookup when installed into the store.

## Checking the whole config

A sweep or audit checks the structure and rules above and also whether the config does its job:

- A fresh host of any class and any feature combination installs and builds without manual fixes
  (first-switch ordering; secrets a feature can't do without fail evaluation with one message
  listing them, missing extras degrade with a warning; nothing assumes node1 or tower).
- The split stays clean: Nix installs and wires, dotfiles hold runtime settings, `hosts/<name>` holds
  the choices; nothing the framework on `main` needs lives outside `modules/`.
- n hosts in any cluster shape work: relations come from `cluster.toml` and the contracts, never
  from host names.
- Server state that lives only in a service's UI is named, and backed up or reproducible.
- A building block stays only while it is the plain, common choice for its job.

Checking one service: its lines and levels in Loki (by `service_name`, the top repeated messages,
everything above info), what only its UI holds (named in the module header), what it should tell
or trigger in another service (a built-in connection or an n8n workflow), and its backup.

## Commands

```sh
git add --intent-to-add .      # flakes ignore untracked files; new files need this
nix flake check                # evaluates every host: the bar for "done"
nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath
nix fmt
# a change that shouldn't alter any system: same derivation as the last commit
nix eval --raw "git+file://$PWD?ref=HEAD#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
```

`nix flake check` catches types, missing options and bad references, not a package that fails
to build or a service that fails to start. Say when a change is unverified and why.

Modules find dotfiles in the host's checkout (`axon.repo`) at runtime, not in a session folder: a
switch from `~/sessions/<repo>` brings the Nix code, the dotfiles only arrive with commit, push
and pull.

## Logs and metrics

The host that lists `monitoring` keeps every host's journal in Loki (`:3100`) and their metrics in
Prometheus (`:9090`), both open on the tailnet without a login; read them directly instead of
asking the owner for logs. Log labels: `host`, `unit`, `service_name` (the `axon.services` entry),
`level` (journald's keywords: `err`, `warning`, …), `container`.

A service's log reaches Loki with the right level when its lines name one (`[error]`, `level=warn`,
`ERROR`, a syslog prefix, JSON `"level"`).

```sh
loki=http://<monitoring host>:3100 prom=http://<monitoring host>:9090
curl -sG $loki/loki/api/v1/query_range --data-urlencode 'query={service_name="downloads",level=~"err|crit"}' \
  --data-urlencode since=24h --data-urlencode limit=50 | jq -r '.data.result[].values[][1]'
curl -sG $prom/api/v1/query --data-urlencode 'query=ALERTS{alertstate="firing"}' | jq '.data.result'
```

## Boundaries

**Never:** change the repository with git (`git add --intent-to-add` is the one exception; reading
it with `status`, `log`, `diff`, `show`, `blame` or `rev-parse` is fine); run disko against an
existing machine.

**Ask first:** anything in `hosts/` (host.toml, facter.json, dotfiles), secrets and `.sops.yaml`,
new flake inputs, new features or classes.

Moves and deletes outside `hosts/` need no asking; say what moved.

**Deliberate, don't "fix":** everything in [DECISIONS.md](DECISIONS.md).
