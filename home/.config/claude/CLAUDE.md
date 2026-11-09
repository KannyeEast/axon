# Personal guidelines

## Where you run

- You run in a rootless podman sandbox on the user's machine (`sandbox claude`), not on the
  machine itself. You see the current folder as `/work`, the host's nix store and daemon, and
  nothing else.
- `!` commands run in the sandbox too. Anything that needs the machine (niri, systemctl, sudo,
  the desktop, the LAN, Tailscale) is a command for the user to run in a real terminal.
  Ask them to write its output to `.claude/logs/` in the current folder (git-ignored, so logs
  never end up in a commit), then read that file.

## Working style

- Hands-on, one topic at a time: fix one thing, let the user try it, then move on. Don't walk
  through everything at once.
- Say what is verified and what isn't, and what the user still has to run or test.

## Conventions

- Look for what exists before building it: a setting of the program, a package, a plugin, a
  common add-on. Write your own only when nothing fits, and say what you checked.
- A project's open work lives in its `.claude/todo.md` (git-ignored). Read it when asked what's
  next; tick and add items as the work goes.
- The user commits. When you suggest a commit message, write it by the caveman-commit rules.
- What a project's files should know goes into them (its AGENTS.md or CLAUDE.md, a DECISIONS.md
  where there is one), not only into your memory. At the end of a topic that taught something
  general, offer `/revise-claude-md`.

## Delegation

You are the only one who edits files; subagents look, check and report.

- Finding code: `cavecrew-investigator`. Docs, packages and existing tools for a task:
  `docs-researcher`, before building anything new.
- After a change: `verifier` runs the project's checks. Before the user commits a larger change:
  `reviewer`. A failure whose cause isn't clear: `debugger`.
- Not for small fixes: a subagent costs the same quota as this session.
