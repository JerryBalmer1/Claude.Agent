# Changelog

## Unreleased

- Egress allowlist (Claude.Agent.Network design 4): the sidecar forwards only `api.anthropic.com` and refuses and
  records everything else. Smoke asserts the capture's allowed hosts are exactly `api.anthropic.com` and, on a
  `claude -p` run, that `http-intake.logs.us5.datadoghq.com` is among the refused. The report's `capture` gains
  `allowedHosts`, `refusedHosts`, `summary {allowed, refused, refusedHosts}` and `refused` (the refused flows).

- No route out but the sidecar: the agent is on the internal `inside` network only (networks come from
  Claude.Agent.Network's fragment). The entrypoint ledgers `agent.egress-check {directBlocked}` from a direct
  `curl --noproxy '*'` before `agent.start` and exits 3 if it was not blocked.
- Ledger key out of the agent: new `ledger` service (`ledger.Dockerfile`, `mcr.microsoft.com/powershell:7.4-debian-12`,
  uid 10002, no network) runs `Start-LedgerKeeper`. The agent writes to the `spool` volume only; the `ledger`
  volume is mounted into the keeper alone. Shared group `spool` (gid 10100) in both images.
- Smoke: drains the spool, requires the keeper to exit 0 on SIGTERM, reads the ledger with the keeper image,
  asserts egress blocked, agent on `inside` only, `inside` internal with only `agent` and `mitm`, no `key.bin`
  in the agent image, no `/ledger` mount on the agent. Report gains `run`, `egress`, `isolation`, `keeper`.
- A run starts at `agent.egress-check`. With `ANTHROPIC_API_KEY` in the environment or `.env`, Smoke and Pester
  require `agent.run` with exit 0 and `ok` in the reply; without one, the probe path runs and that test is skipped.

## 0.1.0 - 2026-10-08

- Agent image: `node:22-bookworm-slim`, PowerShell 7.4 (Microsoft apt repo), `@anthropic-ai/claude-code@2.1.295`,
  curl, ca-certificates, non-root user `agent`, workdir `/work`, Claude.Agent.Ledger and Claude.Agent.Network baked in.
- `entrypoint.ps1`: installs the mitmproxy CA, ledgers `agent.start`, then `agent.run` (with a key) or
  `agent.probe` (without), then `agent.stop`.
- `compose.yaml`: project `claude-agent-dev`, includes the Network sidecar, proxy env, `ledger` and `mitm-ca:ro` volumes.
- `.build.ps1`: Modules, Image, Up, Smoke, Down, Pester; Clean drops volumes.
- `tests/Smoke.Tests.ps1` asserts `artifacts/smoke-report.json`.
