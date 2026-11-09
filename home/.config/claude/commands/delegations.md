---
description: Which subagents the recent sessions of this project delegated to, and how often
allowed-tools: Bash
---

Delegations per session, newest first (subagent type and count; built-in types included):

!`cd ~/.claude/projects/"$(pwd | sed 's#[/.]#-#g')" && for f in $(ls -t *.jsonl | head -5); do echo "== ${f%.jsonl} ($(date -r "$f" '+%F %H:%M'))"; jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Agent") | .input.subagent_type // "general-purpose"' "$f" | sort | uniq -c | sort -rn; done`

Show this as a short table per session. Then say, in one or two sentences, whether the roles in
CLAUDE.md's Delegation section were used where they should have been, judging by what those
sessions did. No more than that.
