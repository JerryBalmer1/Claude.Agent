# Claude.Agent

A container image that runs Claude Code under a tool policy and two independent records, and one
`Invoke-Build` that proves the whole thing works end to end:

- a **tool policy** every tool call passes: Claude Code's PreToolUse hook decides each call against a
  `policy.json` generated at image build from emitter ontologies (Claude.Agent.Policy), denies with exit 2,
  and spools every decision to the ledger. Deny by default; reads allowed, writes only under `/work`,
  deletes denied, shell commands allowed but witnessed,

- a **ledger** of what the agent says it did: the agent spools unsigned entries, and a `ledger` sidecar it
  cannot reach chains and HMACs them with a key the agent never holds, and
- a **network capture** the agent cannot touch: the agent sits on an internal network whose only way out is
  the mitmproxy sidecar, so every request goes through it whether or not the agent honours its proxy settings.
  The sidecar forwards only `api.anthropic.com`; any other host is refused with a 403 and recorded as refused.

A green `Invoke-Build` means: both images build, the agent cannot reach the internet directly, it reaches
`api.anthropic.com` through the proxy (a real `claude -p` with a key, a `curl` probe without), the keeper
drains the spool into a ledger that verifies on the host, the agent has neither the key nor the ledger, and
the capture shows the call, with `api.anthropic.com` the only host let through (and, on a `claude -p` run,
Claude Code's Datadog telemetry intake among the refused). On a `claude -p` run it also means the hooks
ledgered allow (read), allow (write under `/work`), deny (delete) in that order and the file is still there,
and Claude.Agent.Alerts, reading the copied ledger on the host, raised exactly one error: that deny.

## Containers

| Service | Image | Networks | Volumes |
| --- | --- | --- | --- |
| `agent` | `claude-agent:dev` (Dockerfile) | `inside` only | `spool` rw, `mitm-ca` ro |
| `ledger` | `claude-agent-ledger:dev` (ledger.Dockerfile, `mcr.microsoft.com/powershell:7.4-debian-12`, uid 10002) | none | `spool` rw, `ledger` rw |
| `mitm` | `mitmproxy/mitmproxy:12.2.3` (from Claude.Agent.Network) | `inside` and `outside` | `mitm-ca`, `capture` |

`inside` is `internal: true`: no gateway, so the agent's only route anywhere is `mitm`. `HTTP_PROXY` /
`HTTPS_PROXY` are still set on the agent as a convenience. Before it starts, the agent checks that
`curl --noproxy '*' https://api.anthropic.com/` fails, ledgers `agent.egress-check {directBlocked}`, and exits
non-zero if it did not fail.

## Four repos

All four sit side by side; this repo finds the others at `../`.

| Repo | What it holds |
| --- | --- |
| `Claude.Agent` (this) | Dockerfile, `ledger.Dockerfile`, entrypoint, `compose.yaml`, the end-to-end build |
| `Claude.Agent.Ledger` | PowerShell module, two roles: writer `Add-LedgerEntry -Spool` (agent); keeper `Start-LedgerKeeper`, `New-Ledger` (ledger sidecar); `Get-Ledger`, `Test-Ledger` (host) |
| `Claude.Agent.Network` | `compose/sidecar.yaml` (mitmproxy, networks `inside`/`outside`) and host-side `ConvertTo-NetworkCapture`, `Get-NetworkCapture` |
| `Claude.Agent.Policy` | PowerShell module `New-Policy`, `Test-Policy`, `Resolve-PolicyDecision`; `schemas/policy.schema.json`; `hooks/` (pre-tool-use, post-tool-use, settings fragment) |
| `Claude.Agent.Alerts` | Host-only PowerShell module `Invoke-LedgerAlert`, `Export-LedgerAlert`, `Get-LedgerAlertSummary`, `Test-AlertRule`: rules over the ledger, findings as a GraphNode layer |
| `Graph.Node` | GraphNode, the `graph/1` envelope shape and validator the alerts layer is written in (read-only reference) |

`vendor/Graph.Emitter.FileSystem/ontology.yaml` is a checked-in copy of that emitter's ontology; the image
generates its policy from it. Modules prints a warning when the emitter's own copy (`../Graph.Emitter.FileSystem`) differs.

## Requirements

Docker Desktop (Compose v2.24+), PowerShell 7.4+, `InvokeBuild`, `Pester` 5.5+.

## Project name and host port

| Setting | Default | What |
| --- | --- | --- |
| `COMPOSE_PROJECT_NAME` | `claude-agent-dev` | Compose project; names the containers, networks (`<project>_inside`, ...) and volumes (`<project>_ledger`, ...) |
| `CLAUDE_AGENT_PORT` | `8300` | Host port reserved for an Alerts/Ledger API; published by nothing yet (commented `ports:` on the keeper) |

`.build.ps1` takes each from `-Project` / `-Port`, else `.env`, else the environment, else the default
(`.env.example`), exports both and passes `--project-name` on every `docker compose` call (design 9). No service
publishes a host port: Smoke fails on any port but the reserved one, and `Invoke-Build Status` prints the
project, the networks and volumes it owns, and fails if any host port is published.

## Build order

`Invoke-Build` in this repo runs, in order:

1. **Modules**: copy `src/<Module>` of `../Claude.Agent.Ledger`, `../Claude.Agent.Network` and `../Claude.Agent.Policy` into `build/modules/` (fails if a sibling is missing); copy Policy's `schemas/` into its module, and its `hooks/*.ps1` and `hooks/settings.json` into `build/policy/`. Copy `../Claude.Agent.Alerts/src/Claude.Agent.Alerts` and `../Graph.Node/src/GraphNode` into `build/host-modules/`, which no image gets (design 7).
2. **Image**: `docker compose build agent ledger`: the agent (node:22-bookworm-slim, PowerShell 7.4, Claude Code 2.1.295, the three modules) and the keeper (PowerShell 7.4, the ledger module only). The agent build runs `New-Policy` and `Test-Policy` against the vendored ontology and bakes `policy.json`, the hooks, `settings.json` and the ontology at `/opt/agent/policy`, owned by root, directories `0555`, files `0444`.
3. **Up**: `docker compose up -d`; `mitm` and `ledger` must be healthy before `agent` (`ledger` is healthy once its start-up seq sync has written `/spool/seq`, design 8); wait for `agent` to exit 0. Prints which run path (run or probe) it took.
4. **Smoke**: stop `agent`; poll until the keeper has drained `/spool/pending.jsonl` (30 s cap); stop `ledger` (it flushes on SIGTERM; must exit 0) and `mitm` (flushes the capture); copy the ledger volume out with a one-shot container, `Test-Ledger`; check that the agent image has no `key.bin`, the agent container has no `/ledger` mount and sits on `inside` only, and that `inside` is internal with only `agent` and `mitm` on it; convert and read the capture; read the baked policy and its file owners and modes from the image, take the `policy.*` entries from the ledger, and `docker cp` `/work/policy-smoke.txt` out of the stopped agent; check that no host port but `CLAUDE_AGENT_PORT` is published (config and containers); write `artifacts/smoke-report.json`, and fail if any fact is missing.
5. **Alerts**: run `Invoke-LedgerAlert` on `artifacts/ledger/ledger.jsonl` from the last `agent.egress-check` on, write `artifacts/alerts/<yyyyMMddTHHmmssZ>.graph.json` (the layer stamp; plus `ontology.yaml`) with `Export-LedgerAlert`, copy the newest to `artifacts/alerts/latest.graph.json` for the portal, check them with `Test-Graph -Strict` and with Graph.Node's `graphnode validate --ontology` against Claude.Agent.Alerts' shipped `ontology.yaml` (must print `[]`), and add `alerts {fromSeq, total, bySeverity, byRule, errors[], findings[], envelope {path, valid, nodes, edges, latest, latestIsNewest, ontology, validate[]}}` to the report. On a `claude -p` run there must be exactly one error, the smoke delete's `policy.deny`; on a probe run, none.
6. **Down**: `docker compose down` (volumes kept).
7. **Pester**: `tests/Smoke.Tests.ps1` asserts the report.

`Invoke-Build Clean` also removes the volumes (spool, ledger, CA, capture) and `build/`, `artifacts/`.
`Invoke-Build Status` is not in the chain: project name, its networks and volumes, and the host-port check.
Each sibling has its own `Invoke-Build` for its unit tests.

## Running with and without a credential

Two credentials are accepted; set one, never both:

- `CLAUDE_CODE_OAUTH_TOKEN` (primary): for a Claude subscription. Create it with `claude setup-token`.
- `ANTHROPIC_API_KEY` (fallback): an API key, if you have no subscription.

Copy `.env.example` to `.env` and fill in one, or export it in the shell (the shell wins over `.env`). Compose
passes both to the container as `${VAR:-}` at run time; neither is ever in the image or in git. The build and the
entrypoint only check which one is non-empty and never print or write a value. If both are set, the build fails
in Up and the entrypoint refuses to start with a message.

Without a credential the agent runs `curl https://api.anthropic.com/v1/models` through the proxy and ledgers the
HTTP status as `agent.probe` (expect `401`). The report says `"run": {"auth": null, "path": "probe"}` and the
`claude -p` test is skipped.

With one, the entrypoint first merges `/opt/agent/policy/settings.json` (PreToolUse and PostToolUse hooks,
matcher `*`) into `~/.claude/settings.json`, then runs `claude -p --output-format text --max-turns 12` with a
three-step prompt: Read `/etc/hostname`, Write `/work/policy-smoke.txt`, delete it (without saying how), and end
the reply with a line `ok`. It ledgers `agent.run {auth, exitCode, output, smokeFile, smokeExists}`. Smoke and
Pester require `agent.run` with the same `auth`, exit 0 and a last line of `ok`; among the hooks' `phase: pre`
entries, `policy.allow File.read`, `policy.allow File.write`, `policy.deny File.delete` in that order; no
`phase: post` entry with `policy.deny` (nothing denied ran); and the file still in the stopped container.
The report's `policy` block holds `rules`, `files` (owner, mode), `decisions[]`, `preSequence`, `afterDeny`
(calls claude made after the deny) and `smokeFileExists`.

## Where things end up

| What | Where |
| --- | --- |
| Spool | volume `claude-agent-dev_spool` (`pending.jsonl`, `seq`); shared by `agent` and `ledger` (group `spool`, gid 10100), empty once the keeper has drained it |
| Ledger | volume `claude-agent-dev_ledger` (`ledger.jsonl` and `key.bin`), mounted only into `ledger`; kept across runs, so entries accumulate and the chain continues |
| mitmproxy CA | volume `claude-agent-dev_mitm-ca`, mounted read-only into the agent |
| Capture | volume `claude-agent-dev_capture` (`flows.mitm`), never mounted into the agent |
| Policy | `/opt/agent/policy` in the agent image: `policy.json`, `settings.json`, `hooks/`, `ontology/`; root-owned, read-only |
| Copies for the host | `artifacts/ledger/ledger.jsonl`, `artifacts/capture.json`, `artifacts/smoke-report.json` (gitignored; the key is deleted after verification) |
| Alerts layer | `artifacts/alerts/<yyyyMMddTHHmmssZ>.graph.json`, `artifacts/alerts/latest.graph.json` (copy of the newest, for the portal) and `ontology.yaml` (GraphNode `graph/1`, module `Claude.Agent.Alerts`) |

See [docs/design.md](docs/design.md) for why it is built this way.
