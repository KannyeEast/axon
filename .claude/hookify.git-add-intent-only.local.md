---
name: block-git-add-without-intent
enabled: true
event: bash
action: block
conditions:
  - field: command
    operator: regex_match
    pattern: \bgit\s+add\b
  - field: command
    operator: not_contains
    pattern: --intent-to-add
---

AGENTS.md, Boundaries: `git add --intent-to-add` is the only git command that may change this
repository. Staging is the user's; register new files with `git add --intent-to-add <path>`.
