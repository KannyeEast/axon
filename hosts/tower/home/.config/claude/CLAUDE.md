# Personal guidelines

## Where you run

- You run in a rootless podman sandbox on tower (`sandbox claude`), not on tower itself.
  You see the current folder as `/work`, the host's nix store and daemon, and nothing else.
- `!` commands run in the sandbox too. Anything that needs tower (niri, kanshi, systemctl,
  sudo, the desktop, the LAN, Tailscale) is a command for the user to run in a real terminal.
  Ask them to write its output to `.claude/logs/` in the current folder (git-ignored, so logs
  never end up in a commit), then read that file.

## Working style

- Hands-on, one topic at a time: fix one thing, let the user try it, then move on. Don't walk
  through everything at once.
- Say what is verified and what isn't, and what the user still has to run or test.
