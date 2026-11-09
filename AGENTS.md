# AGENTS.md

Instructions for an assistant working in this repository.

## Roles

This repository is a NixOS configuration built on a small framework (axon) that lives in it. Two
assistants work on it with the same knowledge (this file and [DECISIONS.md](DECISIONS.md)) and
different jobs. Started by CI on a pull request, you are the reviewer; otherwise the author.

**Author.** You change the configuration with its owner, in a conversation. Explain, then act:
say what you found and what you intend to change before editing. Stop for confirmation on
anything beyond a single obvious fix, and don't bundle unrequested changes. Say what you verified
and what you didn't. Asked to fix the review, read its open findings (`just findings`, which runs
`.forgejo/findings.sh`) and fix each one, or say why not.

**Reviewer.** You check a pull request and change nothing. Follow
[.forgejo/review.md](.forgejo/review.md). Every finding names the rule it breaks, why that
matters here, and the concrete fix. A choice recorded in DECISIONS.md is not a finding.

## Layout

```
flake.nix            inputs; outputs = every .nix under modules/ (import-tree)
cluster.toml         relations between machines: [ssh], [sync], [external]; the repo's remotes: [repo]
DECISIONS.md         deliberate choices that look like mistakes; never "fixed" or flagged
.forgejo/            CI: check and review on pull requests, main published from stable; the reviewer's guide;
                     findings.sh, the latest review's open findings for the author
hosts/<name>/        host.toml, facter.json, secrets.json (sops), optional home/
hosts/_old/          previous hosts, kept for reference, never built
home/                dotfiles every host shares; hosts/<name>/home wins per file
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

## Rules

- **Setting, derived value, or host data?** Same on every host: just set it. Differs and can be
  detected: derive it (facter). Differs and is a choice: a field in `host.toml`. A different
  behaviour: a feature, never an option.
- **Use what exists before building it.** Before a custom script, wrapper or option, look for
  what already does it: a setting of the NixOS module or the program itself, a package or plugin
  in nixpkgs, a common add-on (the program's docs, its issue tracker, the web). Write your own only
  when nothing fits, and say in your reply what you looked at.
- **Core, class or feature?** Core: a machine can't boot, log in or be managed from this repo
  without it. Class: the barest machine of that class needs it. Feature: you can name a host of
  that class that wouldn't want it.
- **A feature is an area, not a program.** Add a new service to the feature whose area it is.
  Parts that only fit one class check `config.axon.host.class` inside the feature. Split a feature
  only when a named host wants one part and not the other.
- **A dependency is a hard need or an extra.** A hard need is `requires` or an assertion. Anything
  that can work without the other piece must, and the piece only adds to it; never fail silently.
  Features read contracts, not each other's names; the feature lists in `cluster.hosts` are the
  only cross-host data, so reading those is fine.
- **Dotfiles are runtime, user-space files.** Nix never reads `home/`. Nix installs programs and
  loads what needs a store path; settings live in dotfiles.
- **Contracts are declared in core**: `axon.services` (routes, backup paths), `axon.persist`,
  `axon.volumes`, `axon.spaces` (a service's own subvolume, capped by `[limits]`), `axon.mail`,
  `axon.vpn`, `axon.overlay`, `axon.browser`. Add one for two or more consumers or a realistic swap. Producers set them unconditionally; consumers handle an empty set or null.
- **One way per thing.** Modules that produce the same result do it the same way. A shared helper
  only when many modules use it.
- **Only what changes something.** Don't restate an upstream default (read the module's source),
  and don't add an option nothing sets, a helper with one caller or a package nothing runs. A
  port stays written out even when it is the default: the route needs the number. The framework
  (`modules/`, published on `main`) serves any machine, not only these hosts: what another
  host could plausibly need (another architecture, disk layout or class) is not dead weight.
- **A change takes its references with it.** Renaming, replacing or removing something (a
  program, a unit, a script, an option, an app id, a path) means searching the whole repository
  for it, `home/` and `hosts/*/home` included, and updating every place in the same change.
- **State lives next to the module that creates it**, in the same file: a feature adds its path to
  `axon.persist.state.directories` (on the host's state volume when it has one), core and classes
  to `axon.persist.directories` (the boot disk). `DynamicUser` services keep state in
  `/var/lib/private/<name>`.
- **Name files for what they do** (`passwords.nix`, not `keepassxc.nix`).
- **Formatting**: `nix fmt`. Never align `=` or values with extra spaces, in any file type.
- **Errors** read `<file or option>: <what is wrong>`, and say what to do where possible.
- **Decisions are written down.** A deliberate choice that the comment on its lines explains
  stays in that comment. One that spans files or is about something deliberately missing goes
  into DECISIONS.md with its reason, in the same commit.
- **Comments describe the code as it is, not how it got there.** A module's header says what
  that module does. Inline comments only where the code isn't obvious on its own. No history,
  rejected alternatives or reasoning from a conversation: that belongs in the commit message.
- **Quirks are explained where they're handled.** A workaround for a tool, driver or service gets
  a comment on the lines that do it, saying what breaks without them.
- **Dotfiles with several sections** separate them with a ruler: `# ── name ────────`
  (`--` in Lua, `//` in KDL and JavaScript).

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

## Boundaries

**Never:** change the repository with git (`git add --intent-to-add` is the one exception; reading
it with `status`, `log`, `diff`, `show`, `blame` or `rev-parse` is fine); run disko against an
existing machine.

**Ask first:** anything in `hosts/` (host.toml, facter.json, dotfiles), secrets and `.sops.yaml`,
new flake inputs, new features or classes.

Moves and deletes outside `hosts/` need no asking; say what moved.

**Deliberate, don't "fix":** everything in [DECISIONS.md](DECISIONS.md).
