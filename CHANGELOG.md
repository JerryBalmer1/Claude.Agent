# Changelog

## 0.4.5 - 2026-10-09

- 0.4.5: Up exports the run to 8200; policy.json to host; snapshot entries; Up replaces
- Visibility: Up ends by waiting for the keeper to drain, copying `ledger.jsonl` (never `key.bin`) to
  `artifacts/ledger/`, importing `../Graph.Emitter.Agent` (0.1.2), running `Export-AgentRunGraph -LedgerPath
  artifacts/ledger/ledger.jsonl -PolicyPath artifacts/policy.json -LayersPath artifacts/layers -Strict`, POSTing the
  layer's path to `http://127.0.0.1:8200/api/layers` as layer `agent-runs`, and printing
  `agent run <stamp> at http://127.0.0.1:8200/ (<n> nodes, <m> edges)`. With nothing on 8200 it prints the layer path
  and `portal not up on 8200` and carries on. `-NoPortal` skips the export. Design 11.
- `artifacts/policy.json`: Up copies the image's `/opt/agent/policy/policy.json` out byte for byte before the run, so
  its SHA-256 is `agent.start`'s `policySha256` and the export gets rule text without `docker cp`.
- Snapshots (Claude.Agent.Ledger 0.2.4 handoff): the entrypoint spools `agent.snapshot` (`Get-AgentSnapshot -At
  agent.egress-check`) right after the egress-check entry and `-At agent.stop` just before `agent.stop`. Up hands the
  image id in as `CLAUDE_AGENT_IMAGE_DIGEST` (new `compose.yaml` variable), so `imageDigest` is not null. Smoke checks
  the order egress-check, snapshot, start, ..., snapshot, stop and the digest; the report's `ledger` gains
  `snapshots`, `imageDigest` and `policySha256`.
- Ledger 0.2.4 workaround: `Add-LedgerEntry` and `Get-Ledger` parse a line without `-AsHashtable`, which throws on a
  snapshot env holding `HTTP_PROXY` and `http_proxy`. The entrypoint drops only that error after the line is spooled
  (`Add-SnapshotEntry`); Smoke and Alerts read `ledger.jsonl` with `ConvertFrom-Json -AsHashtable`. To be fixed in
  Claude.Agent.Ledger.
- Up replaces a stack that is up: `docker compose down`, wait up to 30 s for its containers to go, up, log
  `replaced <old stamp> with <new stamp>` (a stack's stamp is its agent container's start). `-NoReplace` throws and
  touches nothing. The shape of Portal 0.3.4's Up.
- Smoke clears `artifacts/` except Up's outputs (`policy.json`, `layers/`, `up.json`). Up records what it did in
  `artifacts/up.json`. New `tools/Up.ps1` (helpers) and `tests/Up.Tests.ps1` (helpers without Docker, the
  entrypoint and compose wiring, and `up.json` from the real run).

## 0.4.4 - 2026-10-08

- 0.4.4: git-guard hook; run-report 0.2.2; graph-node 0.2.1
- Skills git-guard 0.1.0, run-report 0.2.2 and graph-node 0.2.1 copied from Graph HEAD; git-guard's PreToolUse hook merged into `.claude/settings.json`. `tests/Skills.Tests.ps1` checks each copy's version and full text against `git show HEAD:` in Graph, and the hook's exit codes (0, 0, 2, 2, 2, 2 for git status, git add, git commit, git push, git tag, gh pr merge).
- CLAUDE.md: the three skills are copies of Graph HEAD (graph-node was listed as from Graph.Node).

## 0.4.3 - 2026-10-09

- Run report: a new Runs task, last in the chain (after Pester, whose totals the Run node needs), writes the run as
  a Graph.RunReport layer, `artifacts/runs/<layer stamp>.graph.json` plus `artifacts/runs/latest.graph.json` (a
  copy) and `ontology.yaml`, beside the unchanged `smoke-report.json` (design 10). One Run (repo, task, start and
  finish, tasks run, Pester totals, image size, auth path, `alertsLayer`); a Finding per alert (the rule's
  severity), for the egress check and for the published-port check; Decisions for the auth path and for each
  image's reuse; a NotRun per chain task the invocation skipped and for skipped Pester tests; a Touched per file
  written. Run `reports` Finding, Decision and NotRun, Run `touched` Touched, as the run-report ontology declares.
  The task fails unless `graphnode validate --ontology` prints `[]` for both files. Builder: `tools/RunReport.ps1`.
- Cross-link: the Run carries `properties.alertsLayer`, the alerts layer's stamp (0.4.2), so the portal can mount
  both layers and join them. No edge crosses envelopes.
- Skills: `.claude/skills/run-report` (from Graph, 0.2.1) and `.claude/skills/graph-node` (from Graph.Node, 0.2.1),
  unchanged copies; `tests/Skills.Tests.ps1` checks each version against its source and that the files are identical.
- `tests/Invoke-Tests.ps1` writes `artifacts/pester.json` (passed, failed, skipped) and exits non-zero on any
  failure, as before. `tests/RunReport.Tests.ps1` builds a run report from the run's own artifacts and checks it.
- CHANGELOG: the old Unreleased section is split into the dated releases it shipped in.

## 0.4.2 - 2026-10-09

- Port: host port `CLAUDE_AGENT_PORT` (default 8300, `.env.example`) is reserved for an Alerts/Ledger API and
  published by nothing yet; `compose.yaml` carries it as a commented `ports:` line on the keeper. No service may
  publish any other host port: Smoke fails on one (report `ports {reserved, published[], stray[]}`), and the new
  Status task fails if any host port is published (design 9).
- Project name: `COMPOSE_PROJECT_NAME` (default `claude-agent-dev`). `.build.ps1` reads it and the port from `.env`,
  else the environment, else the defaults (`-Project` / `-Port` override), exports both, and passes
  `--project-name` on every `docker compose` call. The report records `project`. New Status task: project name,
  the networks and volumes it owns, and the host-port check.
- Alerts artifact path: the layer stays at `artifacts/alerts/<layer stamp>.graph.json` (`yyyyMMddTHHmmssZ` of its
  `layer`), and `artifacts/alerts/latest.graph.json` is a copy of the newest, for the portal. Alerts runs Graph.Node's
  `graphnode validate --ontology` on both against Claude.Agent.Alerts' shipped `ontology.yaml` and requires `[]`;
  the report's `alerts.envelope` gains `latest`, `latestIsNewest`, `ontology`, `validate[]`.

## 0.4.1 - 2026-10-08

- Alerts task: the envelope path in the report is made with `.Replace('\', '/')`; the `-replace '\', '/'` it
  replaced is an invalid regex and failed the task on every run.

## 0.4.0 - 2026-10-08

- Alerts (design 7): Modules copies the fifth sibling, Claude.Agent.Alerts, and Graph.Node's GraphNode into
  `build/host-modules/` (in `.dockerignore`; no image gets them). A new Alerts task after Smoke runs
  `Invoke-LedgerAlert` over the last run of `artifacts/ledger/ledger.jsonl`, writes the GraphNode layer to
  `artifacts/alerts/<utcStamp>.graph.json`, and adds `alerts {fromSeq, total, bySeverity, byRule, errors[],
  findings[], envelope}` to the report. Alerts and Pester require exactly one error finding on a `claude -p`
  run, the smoke delete's `policy.deny`, and none on a probe run. Chain: Modules, Image, Up, Smoke, Alerts, Down, Pester.
- Report: `capture.anthropic` is now `capture.allowed`, the flows the allowlist let through (it was the flows
  to `api.anthropic.com`, refused or not). Pester checks they are all `api.anthropic.com` and that no
  `api.anthropic.com` flow was refused.
- Keeper first (design 8): `ledger` has a healthcheck (`/spool/seq` exists) and `agent` waits for
  `service_healthy` instead of `service_started`, so the keeper's seq sync is done before the agent writes.
- Clean also removes `build/policy` and `build/host-modules`.

## 0.3.0 - 2026-10-08

- Tool policy (Claude.Agent.Policy, design 6): Modules copies the fourth sibling; the image generates
  `policy.json` from `vendor/Graph.Emitter.FileSystem/ontology.yaml` with `New-Policy`, checks it with
  `Test-Policy`, and bakes it with the hooks and `settings.json` root-owned and read-only at `/opt/agent/policy`.
  The entrypoint merges the hooks into `~/.claude/settings.json` and ledgers the policy's SHA-256 in `agent.start`.
- The `claude -p` prompt now reads `/etc/hostname`, writes `/work/policy-smoke.txt` and deletes it. Smoke asserts
  `policy.allow File.read`, `policy.allow File.write`, `policy.deny File.delete` in order, no denied call ran,
  and the file survived (`docker cp` from the stopped agent). The report gains `policy {generated, default,
  rules, files, decisions[], preSequence, sequenceMatched, afterDeny, smokeFile, smokeFileExists}`.
- The `ok` check now requires the reply's last line to be `ok`. It used to match `ok` anywhere, and so passed
  a reply that said it was not replying ok.

## 0.2.2 - 2026-10-08

- Egress allowlist (Claude.Agent.Network design 4): the sidecar forwards only `api.anthropic.com` and refuses and
  records everything else. Smoke asserts the capture's allowed hosts are exactly `api.anthropic.com` and, on a
  `claude -p` run, that `http-intake.logs.us5.datadoghq.com` is among the refused. The report's `capture` gains
  `allowedHosts`, `refusedHosts`, `summary {allowed, refused, refusedHosts}` and `refused` (the refused flows).

## 0.2.1 - 2026-10-08

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
