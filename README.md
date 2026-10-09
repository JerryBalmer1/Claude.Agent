# Claude.Agent

A container image that runs Claude Code under two independent records, and one `Invoke-Build` that proves
the whole thing works end to end:

- a **ledger** of what the agent says it did: the agent spools unsigned entries, and a `ledger` sidecar it
  cannot reach chains and HMACs them with a key the agent never holds, and
- a **network capture** the agent cannot touch: the agent sits on an internal network whose only way out is
  the mitmproxy sidecar, so every request goes through it whether or not the agent honours its proxy settings.
  The sidecar forwards only `api.anthropic.com`; any other host is refused with a 403 and recorded as refused.

A green `Invoke-Build` means: both images build, the agent cannot reach the internet directly, it reaches
`api.anthropic.com` through the proxy (a real `claude -p` with a key, a `curl` probe without), the keeper
drains the spool into a ledger that verifies on the host, the agent has neither the key nor the ledger, and
the capture shows the call, with `api.anthropic.com` the only host let through (and, on a `claude -p` run,
Claude Code's Datadog telemetry intake among the refused).

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

## Three repos

All three sit side by side; this repo finds the others at `../`.

| Repo | What it holds |
| --- | --- |
| `Claude.Agent` (this) | Dockerfile, `ledger.Dockerfile`, entrypoint, `compose.yaml`, the end-to-end build |
| `Claude.Agent.Ledger` | PowerShell module, two roles: writer `Add-LedgerEntry -Spool` (agent); keeper `Start-LedgerKeeper`, `New-Ledger` (ledger sidecar); `Get-Ledger`, `Test-Ledger` (host) |
| `Claude.Agent.Network` | `compose/sidecar.yaml` (mitmproxy, networks `inside`/`outside`) and host-side `ConvertTo-NetworkCapture`, `Get-NetworkCapture` |

## Requirements

Docker Desktop (Compose v2.24+), PowerShell 7.4+, `InvokeBuild`, `Pester` 5.5+.

## Build order

`Invoke-Build` in this repo runs, in order:

1. **Modules**: copy `../Claude.Agent.Ledger/src/Claude.Agent.Ledger` and `../Claude.Agent.Network/src/Claude.Agent.Network` into `build/modules/` (fails if a sibling is missing).
2. **Image**: `docker compose build agent ledger`: the agent (node:22-bookworm-slim, PowerShell 7.4, Claude Code 2.1.295, both modules) and the keeper (PowerShell 7.4, the ledger module only).
3. **Up**: `docker compose up -d`; `mitm` must be healthy and `ledger` started before `agent`; wait for `agent` to exit 0. Prints which run path (run or probe) it took.
4. **Smoke**: stop `agent`; poll until the keeper has drained `/spool/pending.jsonl` (30 s cap); stop `ledger` (it flushes on SIGTERM; must exit 0) and `mitm` (flushes the capture); copy the ledger volume out with a one-shot container, `Test-Ledger`; check that the agent image has no `key.bin`, the agent container has no `/ledger` mount and sits on `inside` only, and that `inside` is internal with only `agent` and `mitm` on it; convert and read the capture; write `artifacts/smoke-report.json`, and fail if any fact is missing.
5. **Down**: `docker compose down` (volumes kept).
6. **Pester**: `tests/Smoke.Tests.ps1` asserts the report.

`Invoke-Build Clean` also removes the volumes (spool, ledger, CA, capture) and `build/`, `artifacts/`.
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

With one, the agent runs `claude -p "Reply with the single word ok" --output-format text` and ledgers
`agent.run {auth: oauth|apikey, exitCode, output}`. The report carries `run.auth`, and Smoke and Pester require
`agent.run` with the same `auth`, exit 0 and a reply containing `ok`.

## Where things end up

| What | Where |
| --- | --- |
| Spool | volume `claude-agent-dev_spool` (`pending.jsonl`, `seq`); shared by `agent` and `ledger` (group `spool`, gid 10100), empty once the keeper has drained it |
| Ledger | volume `claude-agent-dev_ledger` (`ledger.jsonl` and `key.bin`), mounted only into `ledger`; kept across runs, so entries accumulate and the chain continues |
| mitmproxy CA | volume `claude-agent-dev_mitm-ca`, mounted read-only into the agent |
| Capture | volume `claude-agent-dev_capture` (`flows.mitm`), never mounted into the agent |
| Copies for the host | `artifacts/ledger/ledger.jsonl`, `artifacts/capture.json`, `artifacts/smoke-report.json` (gitignored; the key is deleted after verification) |

See [docs/design.md](docs/design.md) for why it is built this way.
