# axon

NixOS for my machines, as data plus a small framework.

- A machine is a folder: `hosts/<name>/host.toml` says what it is, `facter.json` what hardware it
  has, `secrets.json` (sops) what it must keep secret.
- `cluster.toml` says how machines relate: who may log in where, which folders sync between whom, and where this repository is pushed (`just remotes`).
- Branches: `dev` for daily work, pushed to Forgejo only; `stable` takes it through a reviewed
  pull request (`just pr`); `main` is the framework alone (`modules/`, `flake.nix` and its lock,
  the installer, this README), built from `stable` after every merge. Only `stable` and `main` go
  to the mirrors.
- `modules/` is found, not wired: core for every host, one class (`desktop` or `server`), and the
  features a host subscribes to, one folder each under `modules/features/`.
- Dotfiles live in `home/`, with `hosts/<name>/home` winning per file, and are linked live into
  `$HOME`; Nix never reads them.

Working on it with an assistant: [AGENTS.md](AGENTS.md); choices that are deliberate: [DECISIONS.md](DECISIONS.md).

## Everyday

```sh
just            # list everything
just switch     # rebuild and activate
just check      # evaluate every host
just update     # update inputs
just secrets    # edit this machine's secrets
just docs       # the host.toml / cluster.toml reference
```

## A new project

```sh
nix flake init -t ~/axon#devshell && direnv allow
```

## A new machine

From the NixOS installer, see `install.sh`.