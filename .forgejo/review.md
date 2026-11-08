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
   A claim like "this restates a default" needs the module source line; "this breaks host X" needs
   the evaluation.
3. If the description says no system changes (a cleanup, a refactor), check it: every host's
   derivation must equal the base branch's.

   ```sh
   nix eval --raw "git+file://$PWD?ref=<base>#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
   nix eval --raw ".#nixosConfigurations.<host>.config.system.build.toplevel.drvPath"
   ```

4. Report only what you verified. Where you can't verify something here (a service starting, a
   value on the machine), say what would confirm it, as a note.

## What to check

### Every change

- **CI.** A failed `nix flake check` or build is the first finding: the cause read from the log,
  the file and line it comes from, and the fix.
- **The rules in AGENTS.md**, each of them. The ones most often missed:
  - a setting equal to the upstream default, an option nothing sets, a helper with one caller,
    a package nothing runs (Only what changes something)
  - a custom script or wrapper where a module setting, a nixpkgs package or a common add-on does
    the job (Use what exists before building it)
  - comments that tell history or reasoning instead of what the code does
  - errors not shaped `<file or option>: <what is wrong>`; values aligned with extra spaces
  - a dependency that fails or asserts where it could fall back (A dependency is a hard need or
    an extra)
- **Boundaries.** Changes in `hosts/`, secrets, `.sops.yaml`, new flake inputs, new features or
  classes need the owner's yes. Flag them as a note asking whether that was given, unless the
  description says so.

### A new or changed service

- **Route** through `axon.services.<name>.route`: `access = "login"` unless the service has its own
  login, `public = true` only then (core asserts it). A new route also needs its DNS record at
  Cloudflare, made by hand: a note, so the owner doesn't forget.
- **Listening**: on `127.0.0.1` or inside the VPN namespace; the gateway proxies. Ports for other
  machines only through `axon.overlay`, never `networking.firewall` directly.
- **State**: every directory the service writes survives the reboot, listed in the same file
  (`axon.persist.state.directories` for a feature). Root is wiped on every boot: missing
  persistence loses data, which is **blocking**. `DynamicUser` services keep state in
  `/var/lib/private/<name>`.
- **User data** (files, photos, documents) in its own `axon.spaces` entry, with `units` naming
  every systemd unit that uses it.
- **Data disks mount with `nofail`**: a unit writing to a volume needs `RequiresMountsFor`, or it
  writes to the root filesystem while the disk is missing.
- **Backup**: `backup.paths` for what can't be rebuilt, `exclude` for what can (thumbnails,
  caches); a database is backed up through a dump, not its live files.
- **Start page**: a `dashboard` entry with name, group, icon, and a widget where Homepage has one;
  every `secrets` key it names exists in the gateway host's `secrets.json` (evaluation warns
  otherwise).
- **VPN**: a service that talks to trackers or indexers lists itself in `axon.vpn.confined`.
- **Mail and other contracts are extras**: the service works when `axon.mail` is null or the
  host has no gateway (`axon.routed` false).
- **Class**: parts for only one class check `config.axon.host.class` inside the feature.

### host.toml and cluster.toml

- A new field is an option in `axon.schema.<bundle>` with a type, a default where one makes
  sense, and a description. It is a field only if it differs per host and is a choice; detectable
  values come from facter, behaviour is a feature.

### Features and contracts

- A new feature has `feature.nix` with `description`, `classes` and `requires` where it has a hard
  need. It is an area, not a program: a service that fits an existing feature goes there.
- A feature reads contracts, never another feature's options or names (the feature lists in
  `cluster.hosts` excepted). A new contract needs two consumers or a realistic swap.

### Dotfiles

- Nix never reads `home/` or `hosts/<name>/home`, and modules don't write dotfiles.
- A file in `home/` works on every host: it must not assume a feature is there.
- Several sections get the ruler from AGENTS.md.

### Inputs and packages

- A new flake input follows `nixpkgs` (and `home-manager`) where it takes them.
- A JetBrains plugin is checked for a cast to `JarURLConnection` before it is added
  (`unzip -p <plugin jars> | grep -ac java/net/JarURLConnection` must print 0): such plugins break
  every file lookup when installed into the store.

## Severity

- **blocking**: evaluation or a build fails; data or state is lost; a service, port or secret is
  exposed beyond what the route says; a Boundary is crossed without the owner's yes. The review
  requests changes.
- **should**: breaks a rule in AGENTS.md. It works, but drifts from how the repository is built.
- **note**: a question, something to check on the machine, an optional improvement.

Nothing else: no praise, no summary of what the diff does, nothing `nix fmt` would change.

## Writing a finding

Each finding sits on the line it is about:

```
**should** · Only what changes something
`http_addr = "127.0.0.1";` is already the default
(nixos/modules/services/monitoring/grafana.nix:493).
Why: a restated default reads like a choice, and hides the settings that are.
Fix: delete the line.
```

- First line: the severity, then the rule as AGENTS.md names it (or `CI`, `Boundaries`,
  `Decisions`).
- Then what is wrong, with the evidence: a source line, a command and its output.
- **Why** it matters in this repository, in one sentence.
- **Fix**: the change itself, as code when it is short.

The review's summary is short: whether it requests changes, the number of findings per severity,
and the CI result. With no findings, one line saying so. On a later push, review the current
diff; don't repeat a finding the new commits fixed.
