---
name: run-report
description: Write artifacts/run-report.json, the machine record of an agent task or a build in any repo of the graph family (Graph, Graph.Node, Graph.Emitter.FileSystem, Graph.Emitter.Network, Graph.Emitter.Terraform, Graph.Emitter.AzureDevOps, Graph.Emitter.Git.Repository, Graph.Emitter.Agent, Graph.Emitter.Reference, GraphRenderer). Use at the end of every agent task, after the prose report, and whenever Invoke-Build Report runs. The report is a Graph.Node envelope (module Graph.RunReport) with one node per bullet of the prose report.
version: 0.2.2
---

# Run report

Every task in a repo of the graph family ends with two reports that say the same thing: the prose report in the conversation, and `run-report.json`, a Graph.Node envelope the portal can draw and Jerry can paste into the next conversation. This skill is maintained in Graph (`C:\__Code\Graph\.claude\skills\run-report`) and copied read-only into every sibling, the same rule as `graph-node`. Never edit a copy; recopy it when the `version:` above changes. That `version:` is the one canonical version of this skill: it tracks the run report's envelope and `reference/ontology.yaml`, not Graph's module version, and bumps only when one of them changes (Graph design.md 9). Graph's Pester compares every sibling's copy against it.

## When it fires

- At the end of every agent task in any repo of the family, after you have written the prose report. Write the JSON from the prose, not the other way round.
- When `Invoke-Build Report` runs in Graph, and automatically at the end of Graph's default `Invoke-Build` chain and of `Invoke-Build Down`. Those write the build's facts only (the Run node, a Finding per failed task or sibling, a NotRun when Graph's Pester did not run); they never invent a Decision or a Touched file. A sibling's own `Report` task that calls `New-GraphRunReport` follows the same rule and writes into that sibling.

## Where it writes

- `<repo>\artifacts\run-report.json` in the repo the task or build ran in (`-Repo`), overwritten every run, and nowhere else: a sibling's report never lands in `C:\__Code\Graph\artifacts` (Graph design.md 11). Check that `artifacts/` is ignored there; if it is not, say so in the report rather than editing that repo's `.gitignore` outside the task.
- `-Repo` defaults to the repo of the calling script: the nearest directory with a `.build.ps1` at or above it (so a sibling's `Report` task writes into that sibling), else at or above the current location; with neither, `New-GraphRunReport` throws. Pass `-Repo` explicitly from an agent's ad-hoc script.
- `ontology.yaml` for `Graph.RunReport` is copied beside the file from `reference/ontology.yaml` (the envelope names `ontology.yaml`, relative to its own directory).

`New-GraphRunReport` does both. Import it from the Graph checkout:

```powershell
Import-Module C:\__Code\Graph\src\Graph\Graph.psd1
```

## What it is

A graph/1 envelope (see the `graph-node` skill) with `module: Graph.RunReport`, `version` the Graph module version, `layer` the run's `finishedAt`, `root` the Run node's id, and `ontology: ontology.yaml`. Because it is an ordinary envelope, the portal draws it (`Start-GraphRenderer -Layers <repo>\artifacts` shows it as layer `run-report`), `Test-Graph` validates it, and a later ledger can merge runs.

## Kinds

| Kind | Id | Properties |
|---|---|---|
| Run | `run:<repo folder name>:<startedAt>` | `repo` (absolute path, forward slashes), `task`, `startedAt`, `finishedAt` (UTC ending `Z`), `buildResult` (`succeeded`, `failed`, `not-run`), `pesterPassed`, `pesterFailed`, `pesterSkipped` |
| Finding | `finding:<n>` | `text`, `severity` (`info`, `warn`, `error`) |
| Decision | `decision:<n>` | `text`, `revisit` (`true` when Jerry should reconsider it) |
| NotRun | `notrun:<n>` | `text` (what did not run), `reason` |
| Touched | `touched:<path>` | `path` (relative to the Run's `repo`, forward slashes), `staged` (`true` when `git add`ed) |

Edges: Run `reports` Finding, Decision, NotRun; Run `touched` Touched. Exactly one Run per report. `n` counts from 1 in the order the prose lists them.

## How the agent fills it

Every bullet of the prose report becomes one node of the matching Kind; nothing in the prose that is not in the JSON, and nothing in the JSON that is not in the prose.

- The task itself, its start and end time, the `Invoke-Build` result and the Pester totals: the Run node's properties. Run Pester only as the repo says (`pwsh -NoProfile -File .\tests\Invoke-Tests.ps1`); copy the totals it printed, never estimate.
- "Worth a second look", warnings, surprises, proposals: Finding. `error` when something is broken now, `warn` when it will bite, `info` otherwise.
- Choices you made without asking: Decision, `revisit: true` when you would not bet on it.
- Anything asked for or normally run that did not run (a manual check item, a sibling build, a step skipped for a missing tool): NotRun with the reason.
- Every file you created, changed or deleted: Touched, path relative to the repo, `staged` as `git status` shows it. A deleted file is not Touched (the Pester check is that every Touched path exists); say it in a Finding.

```powershell
Import-Module C:\__Code\Graph\src\Graph\Graph.psd1
New-GraphRunReport -Repo C:\__Code\Graph.Emitter.FileSystem -Task 'add a move verb' `
    -StartedAt '2026-10-08T14:00:00Z' -FinishedAt (Get-Date) -BuildResult succeeded -PesterPassed 41 `
    -Finding @{ text = 'Remove-FileSystemItem has no -Confirm test'; severity = 'warn' } `
    -Decision @{ text = 'move keeps the id rule; the moved node gets a new id'; revisit = $true } `
    -NotRun @{ text = 'manual check 3.1'; reason = 'GraphRenderer not built' } `
    -Touched @{ path = 'ontology.yaml'; staged = $true }, @{ path = 'src/Graph.Emitter.FileSystem/Public/Move-FileSystemItem.ps1'; staged = $true }
```

Then paste the contents of `<repo>\artifacts\run-report.json` (the file it returned) at the end of the prose report.

## How Jerry uses it

He pastes the file into the next conversation, so the record is the same on both sides: what ran, what was decided, what was not run, which files moved. Write it so that it stands on its own without the conversation.

## Validate

`Test-Graph -Path <repo>\artifacts\run-report.json -Strict` must return `Valid: True`. `New-GraphRunReport` runs it and throws on any problem, so a report that was written is valid; if you edit the file by hand afterwards, run it again. `reference/run-report.example.json` is a real report from the task that created this skill.

## Changes

- 0.2.2 (Graph 0.2.8): the report is written once, to `<repo>\artifacts\run-report.json` of the `-Repo` given, never to `C:\__Code\Graph\artifacts` for a sibling; `-Repo` defaults to the repo of the calling `.build.ps1` instead of Graph. Kinds, properties, edges and `reference/ontology.yaml` unchanged; every sibling recopies it, and until it does Status shows `0.2.1 (Graph 0.2.2)` (Graph design.md 11).
- Graph 0.2.3: the version no longer follows Graph's module version; it bumps only when the envelope or the ontology changes (Graph design.md 9). Graph 0.2.2 had stamped this skill 0.2.2 for a wording change (`Start-GraphRenderer` for `Start-GraphPortal`); that is reverted to 0.2.1, the wording kept. Siblings need not recopy.
- 0.2.1: `reference/ontology.yaml` uses Graph.Node 0.2.0's four shapes (Run and Touched `square`, Finding `circle`, Decision `diamond`, NotRun `hexagon`) and `graphnode validate-ontology` returns `[]` on it, no warnings. Kinds, properties, edges and `New-GraphRunReport` unchanged; every sibling recopies it.
- 0.2.0: the family list names the emitters by their new repo names (Graph.Emitter.Network, Graph.Emitter.Terraform, Graph.Emitter.AzureDevOps) and adds Graph.Emitter.Git.Repository, Graph.Emitter.Agent and Graph.Emitter.Reference. Kinds, edges and `New-GraphRunReport` unchanged.
- 0.1.0: initial. Kinds Run, Finding, Decision, NotRun, Touched; edges `reports`, `touched`; `New-GraphRunReport`; written by Graph's default chain, `Down` and `Report`.
