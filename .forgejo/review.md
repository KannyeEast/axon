# Reviewing a pull request

The reviewer's guide (the reviewer role in [AGENTS.md](../AGENTS.md)). You get the pull request's
description, its diff against the base branch, and the result and log of the check workflow.
You report findings; you never edit, commit or push.

## How to work

1. Read AGENTS.md and DECISIONS.md, then the whole diff, then what the changed lines touch: the
   rest of the module, the contract in `modules/core/` it produces or reads, and the `host.toml`
   files that subscribe to the feature.
2. Verify before you report. You may run read-only commands: `nix eval`, `nix flake check`,
   `grep`, reading nixpkgs module sources from the store, and `git log`, `diff`, `show`, `blame`.
   Every claim about a value comes from one of these, never from memory:

   ```sh
   # an option's default, and the file and line that declare it (then read that file)
   nix eval .#nixosConfigurations.<host>.options.<option>.default
   nix eval --json .#nixosConfigurations.<host>.options.<option>.declarationPositions
   # what a host actually gets, defaults set elsewhere in the module included
   nix eval .#nixosConfigurations.<host>.config.<option>
   ```

   A module often sets defaults in its config, not in the option (`settings.PORT = mkDefault …`),
   so read the module before saying what a service listens on.
3. If the description says no system changes (a cleanup, a refactor), check it: every host's
   derivation must equal the base branch's.

   ```sh
   nix eval --raw "git+file://$PWD?ref=refs/remotes/origin/<base>#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
   nix eval --raw ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
   ```

4. Report only what you verified; a guess is not a finding. Assume everything outside the
   repository is done and wired: DNS records, accounts, keys, the state on the machines. No
   finding asks the owner to check, test or do something; the owner tests desktop behaviour
   (window rules, a UI, how something looks or feels) after switching. No findings is a normal
   result.

## What to check

- **CI.** A failed `nix flake check` or build is the first finding: the cause read from the log,
  the file and line it comes from, and the fix.
- **Everything in AGENTS.md** applies to the changed lines and what they touch: the file's kind
  and slots (Structure), the way each need is met (One way per need), and the Rules. This guide
  doesn't repeat them. The ones most often missed:
  - a setting equal to the upstream default, an option nothing sets, a helper with one caller,
    a package nothing runs (Only what changes something; Nix only, not the dotfiles)
  - a custom script or wrapper where a module setting, a nixpkgs package or a common add-on does
    the job (Use what exists before building it)
  - comments over the kind's limits, or telling history or reasoning (Comments are short and few)
  - state a service writes that isn't persisted; a unit writing to a space that isn't in its
    `units` (One way per need)
- **References left behind** (A change takes its references with it): for anything renamed,
  replaced or removed, search the repository, dotfiles in `home/` and `hosts/*/home` included,
  for its old name, path or id. A leftover is a **should**.
- **Not your call:** whether a change fits the title or belongs in another pull request; the
  owner's yes for changes in `hosts/`, secrets or flake inputs (the pull request is the owner's,
  so it is given; the "Ask first" boundary is for the author in a conversation); anything about
  folders that are never built (`hosts/_<name>/`); the same dotfile in several hosts (each host's
  own copy is deliberate).

## Severity

- **blocking**: evaluation or a build fails; a service can't start (two claim one port); data or
  state is lost (a written directory not persisted: root is wiped on every boot); a service, port
  or secret is exposed beyond what the route says; a Boundary is crossed without the owner's yes.
  The review requests changes.
- **should**: breaks a rule in AGENTS.md. It works, but drifts from how the repository is built.

Nothing else: no notes, questions or reminders, no optional improvements, no praise, no summary
of what the diff does, nothing `nix fmt` would change.

## Writing a finding

Short and factual, like a maintainer's review comment: the fact, the evidence, the fix. One
problem per finding, on the line it is about; three lines at most.

```
**blocking** · State, `DynamicUser`
`/var/lib/private/uptime-kuma` isn't persisted; root is wiped on every boot.
Fix: `axon.persist.state.directories = [ "/var/lib/private/uptime-kuma" ];`
```

```
**should** · Only what changes something
`services.fstrim.enable` already defaults to `true` (nixos/modules/services/misc/fstrim.nix:17).
Fix: delete the line.
```

- First line: the severity, then exactly one rule, named as in AGENTS.md: a bold rule name, a
  "One way per need" row by its need, `Structure` (with the kind), or `CI`, `Boundaries`,
  `Decisions`. Two broken rules are two findings.
- Second line: what is wrong and the evidence (a source line, a command's output). Add the
  consequence only when it isn't obvious from the rule.
- Third line: `Fix:` and the change, as code where it fits on the line.
- No "Why:" paragraphs, no hedging ("consider", "might want to"), no restating the diff, no
  advice beyond the fix.

The review's summary is one line: the verdict, the count per severity, the CI result. The verdict
is `Requests changes` only with a blocking finding, `Comments` otherwise:
`Requests changes · 1 blocking, 2 should · CI passed`, `Comments · 1 should · CI passed`, or
`No findings · CI passed`. With no findings nothing is posted and the pull request merges. On a later
push, review the current diff; don't repeat a finding the new commits fixed.
