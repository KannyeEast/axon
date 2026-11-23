# axon

NixOS for my machines, as data plus a small framework. Opinionated but modular: the framework is
a toolset for any owner and any machine; personal choices live in dotfiles, on desktops and
servers alike; a host's `host.toml` describes the host and nothing else.

- A machine is a folder: `hosts/<name>/host.toml` says what it is, `facter.json` what hardware it
  has, `secrets.json` (sops) what it must keep secret.
- `cluster.toml` says how machines relate: who may log in where, which folders sync between whom, and where this repository is pushed (the checkout's remotes, through the system git config).
- Branches: `dev` for daily work, pushed to Forgejo only; `stable` takes it through a reviewed
  pull request (`just pr`), merged when the review has no findings; `main` is the framework alone
  (`modules/`, `flake.nix` and its lock, the installer, the justfile, this README), built from
  `stable` after every merge. Only `stable` and `main` go to the mirrors.
- `modules/` is found, not wired: core for every host, one class (`desktop` or `server`), and the
  features a host subscribes to, one folder each under `modules/features/`.
- Dotfiles are the owner's files, independent of the features: `home/` holds the terminal every
  host uses, `hosts/<name>/home` the rest of that host's (copied between hosts that share it) and
  wins per file. Both are linked live into `$HOME`; Nix never reads them.

Working on it with an assistant: [AGENTS.md](AGENTS.md); choices that are deliberate: [DECISIONS.md](DECISIONS.md).

## Everyday

```sh
just  # list everything
just switch  # rebuild and activate
just check  # evaluate every host
just deploy <host>  # deploy to another host
just pr  # open the pull request into stable
just secrets  # edit this machine's secrets
just docs  # the host.toml / cluster.toml reference
```

## A new project

```sh
nix flake init -t ~/axon#devshell && direnv allow
```

## A new machine

From the NixOS installer, see `install.sh`.

On a desktop, once after the first login: Claude Code installs by itself only the plugins the user
settings name, not those a project enables, so in `~/axon`:

```sh
sandbox claude plugin install shell-scripting@claude-code-workflows --scope project
```
