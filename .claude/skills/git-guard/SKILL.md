---
name: git-guard
description: A Claude Code PreToolUse hook that denies git commit, git push, git tag, any git command with --amend, gh pr merge and gh release create from an agent's Bash or PowerShell tool, so agents in the graph family edit and stage only. Use when wiring the hook into a repo's .claude/settings.json, recopying it into a sibling, testing it by hand, or when a tool call is refused with "git-guard:".
version: 0.1.0
---

# git-guard

Agents in the graph family edit and stage; Jerry commits, pushes and tags from a separate shell. This skill holds the hook that says so at the moment an agent tries. It is maintained in Graph (`C:\__Code\Graph\.claude\skills\git-guard`) and copied read-only into every sibling, the same rule as `run-report`: never edit a copy; recopy the whole folder when the `version:` above changes. That `version:` is the skill's own, bumped only when the hook's behaviour or the fragment changes, never with Graph's `ModuleVersion` (Graph design.md 10). `Get-GraphStatus` shows each sibling's copy in its GitGuard column.

## What it does

`hook.ps1` is a PreToolUse hook. Claude Code pipes the tool call's JSON to it on stdin; it reads `tool_input.command` and, if any pattern below matches, writes

```
git-guard: agents edit and stage only; commits are run by Jerry from a separate shell
```

to stderr and exits 2, which refuses the call and shows the agent the reason. Anything else exits 0, including input that is not hook JSON or has no `command`.

Patterns (PowerShell `-match`, so case-insensitive; `(?m)` so each line of a multi-line command counts):

| Denies | Pattern |
|---|---|
| `git commit`, `git push`, `git tag` | `(^\|[;&\|])\s*git\s+(commit\|push\|tag)\b` |
| any `git ... --amend` | `(^\|[;&\|])\s*git\b[^;&\|\r\n]*\s--amend\b` |
| `gh pr merge` | `(^\|[;&\|])\s*gh\s+pr\s+merge\b` |
| `gh release create` | `(^\|[;&\|])\s*gh\s+release\s+create\b` |

A command counts when it starts a line or follows `;`, `&` or `|`, so `echo hi && git push` is denied and `git status`, `git add -A`, `git log --grep=commit` are not. `git tag -l` is denied too: listing tags is not worth a second pattern.

## Wiring

`settings.fragment.json` is the `hooks` block to merge into the repo's `.claude/settings.json`:

```json
{ "hooks": { "PreToolUse": [ { "matcher": "Bash|PowerShell",
  "hooks": [ { "type": "command", "command": "pwsh -NoProfile -File .claude/skills/git-guard/hook.ps1" } ] } ] } }
```

Merge it: add the one `PreToolUse` entry beside any that are there, never replace the `hooks` object. The matcher covers both shell tools, because on Windows an agent runs commands through PowerShell as often as Bash. The command path is relative to the project directory, where Claude Code runs hooks.

## Test it by hand

From the repo root, in a shell that is not an agent's:

```powershell
'{"tool_name":"Bash","tool_input":{"command":"git status"}}' | pwsh -NoProfile -File .claude/skills/git-guard/hook.ps1; "exit $LASTEXITCODE"
'{"tool_name":"Bash","tool_input":{"command":"echo hi && git push"}}' | pwsh -NoProfile -File .claude/skills/git-guard/hook.ps1; "exit $LASTEXITCODE"
```

Expect `exit 0`, then the git-guard line and `exit 2`. Graph's Pester feeds it `git status`, `git add -A`, `git commit -m x`, `git push`, `git tag v1`, `echo hi && git push` and expects 0, 0, 2, 2, 2, 2.

## Limits

The hook is advisory. It sees only the command text of the Bash and PowerShell tools: `git -C path commit`, a commit inside a script file, `pwsh -Command`, an alias, or another tool gets past it, and a desktop agent can run without this repo's settings. Claude.Agent.Policy is the enforced layer; this hook is the early, explained refusal in front of it.
