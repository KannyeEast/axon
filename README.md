# axon

NixOS for my machines, as data plus a small framework.

- A machine is a folder: `hosts/<name>/host.toml` says what it is, `facter.json` what hardware it
  has, `secrets.json` (sops) what it must keep secret.
- `cluster.toml` says how machines relate: who may log in where, which folders sync between whom.
- `modules/` is found, not wired: core for every host, one class (`desktop` or `server`), and a few
  features (`dev`, `files`, `gateway`, `media`).
- Dotfiles live in `home/` and are linked live into `$HOME`; Nix never reads them.

Why things are the way they are: [DECISIONS.md](DECISIONS.md). Working on it with an assistant:
[AGENTS.md](AGENTS.md).

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
