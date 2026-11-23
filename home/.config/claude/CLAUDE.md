# Personal guidelines

## Where you run

- You run in a rootless Docker sandbox on the user's machine (`sandbox claude`), not on the
  machine itself. You see the current folder (at the same path as on the machine), the host's
  nix store and daemon, and nothing else.
- `!` commands run in the sandbox too. Anything that needs the machine (niri, systemctl, sudo,
  the desktop, the LAN, Tailscale) is a command for the user to run in a real terminal.
  Ask them to write its output to `.claude/logs/` in the current folder (git-ignored, so logs
  never end up in a commit), then read that file.
- Commands you hand the owner that read a system unit's journal need `sudo`; without it
  journalctl shows only the user's own entries and reports "No entries".

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

You plan, edit small things yourself and check what comes back; subagents look, check, report,
and `builder` implements. These are standing instructions: use the agents below when their
trigger applies, without being asked.

- Before adding a script, wrapper, option, package or service: `docs-researcher` looks for what
  exists. Skip it only when you already checked the source yourself and say so.
- Finding code across more than a handful of files: `cavecrew-investigator`.
- How a program, library or module really behaves, when docs are thin or the answer decides a
  change: `source-digger` reads its source at the version in use.
- A question whose answer lives on the web, not in code (a service, DNS, prices, known issues):
  `web-researcher`.
- A Nix change that isn't obvious, or an eval error that doesn't explain itself: `nix-expert`.
- A change of more than 3 files, once the plan is agreed: write the plan (files, what changes,
  how to verify), have `critic` check it (the plan, not your reasoning), fix what it confirms,
  then hand it to `builder`. One builder on the live tree at a time; two only on files that
  don't overlap.
- Before you suggest a commit message for a change of more than 3 files: `reviewer` over the diff,
  and fix what it confirms first.
- An audit or sweep of more than one file: `reviewer` and `docs-researcher` in parallel, then you
  check their findings before reporting them.
- A failure whose cause isn't clear after one look: `debugger`.
- Not for small fixes (up to 3 files, obvious change): a subagent costs the same quota as this
  session.
