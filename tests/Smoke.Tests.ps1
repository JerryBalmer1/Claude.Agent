# Asserts artifacts/smoke-report.json, written by the Smoke task. Run `Invoke-Build` first.

BeforeDiscovery {
    # -Skip is evaluated during discovery, so the run path has to be known here.
    $discoveryPath = Join-Path $PSScriptRoot '../artifacts/smoke-report.json'
    $hasAuth = if (Test-Path $discoveryPath) { [bool](Get-Content $discoveryPath -Raw | ConvertFrom-Json).run.auth } else { $false }
}

BeforeAll {
    $reportPath = Join-Path $PSScriptRoot '../artifacts/smoke-report.json'
    $report = if (Test-Path $reportPath) { Get-Content $reportPath -Raw | ConvertFrom-Json } else { $null }
}

Describe 'Smoke report' {
    It 'exists' {
        $reportPath | Should -Exist
    }

    Context 'image' {
        It 'was built and has a size' {
            $report.image.name | Should -Be 'claude-agent:dev'
            $report.image.sizeBytes | Should -BeGreaterThan 0
        }
    }

    Context 'egress' {
        It 'the agent could not reach api.anthropic.com without the proxy' {
            $report.egress.directBlocked | Should -BeTrue
        }

        It 'the agent is on the internal network only, shared with mitm and nothing else' {
            $report.egress.insideInternal | Should -BeTrue
            @($report.egress.agentNetworks) | Should -Be @("$($report.project)_inside")
            @($report.egress.insideServices) | Should -Be @('agent', 'mitm')
        }
    }

    Context 'project and host ports' {
        It 'names the compose project the build drove' {
            $report.project | Should -Match '^[a-z0-9][a-z0-9_-]*$'
        }

        It 'reserves a host port and publishes no other' {
            $report.ports.reserved | Should -BeGreaterThan 0
            @($report.ports.stray) | Should -HaveCount 0
            foreach ($p in @($report.ports.published)) { $p.hostPort | Should -Be "$($report.ports.reserved)" }
        }

        It 'publishes nothing yet, not even the reserved port' {
            @($report.ports.published) | Should -HaveCount 0
        }
    }

    Context 'ledger key isolation' {
        It 'the agent image has no key.bin' {
            @($report.isolation.agentImageKeyBin) | Should -HaveCount 0
        }

        It 'the agent container has no /ledger mount' {
            $report.isolation.agentHasLedgerMount | Should -BeFalse
            @($report.isolation.agentMounts.destination) | Should -Not -Contain '/ledger'
            @($report.isolation.agentMounts.destination) | Should -Contain '/spool'
        }

        It 'the keeper drained the spool and exited 0 on SIGTERM' {
            $report.keeper.drained | Should -BeTrue
            $report.keeper.exitCode | Should -Be 0
        }
    }

    Context 'ledger' {
        It 'passed Test-Ledger' {
            $report.ledger.valid | Should -BeTrue
            $report.ledger.error | Should -BeNullOrEmpty
        }

        It 'last run is egress-check, start, ..., stop' {
            $report.ledger.lastRunKinds[0] | Should -Be 'agent.egress-check'
            $report.ledger.lastRunKinds[1] | Should -Be 'agent.start'
            $report.ledger.lastRunKinds[-1] | Should -Be 'agent.stop'
        }

        It 'last run has exactly one agent.run or agent.probe' {
            @($report.ledger.lastRunKinds | Where-Object { $_ -in 'agent.run', 'agent.probe' }).Count | Should -Be 1
            $report.ledger.mode | Should -BeIn @('agent.run', 'agent.probe')
        }

        It 'took the run path that matches whether a credential was present' {
            $report.run.auth | Should -BeIn @($null, 'oauth', 'apikey')
            $report.run.path | Should -Be $(if ($report.run.auth) { 'run' } else { 'probe' })
            $report.ledger.mode | Should -Be "agent.$($report.run.path)"
        }

        It 'recorded the Claude Code version' {
            $report.ledger.claudeVersion | Should -Match '\d+\.\d+\.\d+'
        }

        It 'probe got an HTTP status from the API through the proxy' -Skip:$hasAuth {
            $report.ledger.outcome.status | Should -Match '^[1-5]\d\d$'
        }

        It 'claude -p exited 0, ended its reply with ok, and recorded the auth it used' -Skip:(-not $hasAuth) {
            $report.ledger.outcome.auth | Should -Be $report.run.auth
            $report.ledger.outcome.exitCode | Should -Be 0
            @(($report.ledger.outcome.output -split "`n") | Where-Object { $_.Trim() })[-1] | Should -Match '^\W*ok\W*$'
        }
    }

    Context 'capture' {
        It 'has at least one flow to api.anthropic.com' {
            $report.capture.anthropicFlows | Should -BeGreaterOrEqual 1
            $report.capture.hosts | Should -Contain 'api.anthropic.com'
        }

        It 'saw the response, not just the tunnel' {
            @($report.capture.allowed | Where-Object status).Count | Should -BeGreaterOrEqual 1
        }

        It 'let only api.anthropic.com through the allowlist' {
            @($report.capture.allowedHosts) | Should -Be @('api.anthropic.com')
            @($report.capture.allowed.host | Sort-Object -Unique) | Should -Be @('api.anthropic.com')
            @($report.capture.allowed).Count | Should -Be $report.capture.summary.allowed
            @($report.capture.refused | Where-Object host -eq 'api.anthropic.com') | Should -HaveCount 0
        }

        It 'has a summary that matches the flows' {
            $report.capture.summary.allowed + $report.capture.summary.refused | Should -Be $report.capture.flows
            $report.capture.summary.refused | Should -Be @($report.capture.refused).Count
            @($report.capture.summary.refusedHosts) | Should -Be @($report.capture.refusedHosts)
        }

        It 'refused and recorded Claude Code telemetry to Datadog' -Skip:(-not $hasAuth) {
            $report.capture.refusedHosts | Should -Contain 'http-intake.logs.us5.datadoghq.com'
            @($report.capture.refused | Where-Object host -eq 'http-intake.logs.us5.datadoghq.com').status | Should -Contain 403
        }
    }

    Context 'policy' {
        It 'baked a deny-by-default policy from the FileSystem ontology and the tool map' {
            $report.policy.default | Should -Be 'deny'
            $rules = @($report.policy.rules | ForEach-Object { "$($_.kind).$($_.action)=$($_.effect)" })
            $rules | Should -Contain 'File.delete=deny'
            $rules | Should -Contain 'Directory.delete=deny'
            $rules | Should -Contain 'File.read=allow'
            $rules | Should -Contain 'Shell.exec=witness'
            @(($report.policy.rules | Where-Object { $_.kind -eq 'File' -and $_.action -eq 'write' }).paths) | Should -Be @('/work/**')
        }

        It 'baked policy.json and the hooks root-owned and read-only' {
            $paths = @($report.policy.files.path)
            foreach ($p in '/opt/agent/policy/policy.json', '/opt/agent/policy/settings.json', '/opt/agent/policy/hooks/pre-tool-use.ps1', '/opt/agent/policy/hooks/post-tool-use.ps1') {
                $paths | Should -Contain $p
            }
            @($report.policy.files | Where-Object { $_.owner -ne 'root:root' -or $_.writable }) | Should -HaveCount 0
        }

        It 'ledgered allow File.read, allow File.write, deny File.delete in that order' -Skip:(-not $hasAuth) {
            $report.policy.sequenceMatched | Should -BeTrue -Because ($report.policy.preSequence -join ' | ')
            # Calls after the deny (a retry another way, if any) are listed; the list itself must be there.
            $report.policy.afterDeny -is [array] | Should -BeTrue
            $kinds = @($report.policy.decisions | Where-Object phase -eq 'pre' | ForEach-Object kind)
            $kinds | Should -Contain 'policy.allow'
            $kinds | Should -Contain 'policy.deny'
        }

        It 'kept the file the denied delete targeted' -Skip:(-not $hasAuth) {
            $report.policy.smokeFileExists | Should -BeTrue
        }

        It 'every pre decision names a rule, and nothing denied ran' -Skip:(-not $hasAuth) {
            foreach ($d in $report.policy.decisions) { $d.rule | Should -Match '^(rules\[\d+\]|default)$' }
            @($report.policy.decisions | Where-Object { $_.phase -eq 'post' -and $_.kind -eq 'policy.deny' }) | Should -HaveCount 0
        }
    }

    Context 'alerts' {
        It 'ran over the last run and wrote a valid GraphNode envelope' {
            $report.alerts | Should -Not -BeNullOrEmpty
            $report.alerts.fromSeq | Should -BeGreaterThan 0
            $report.alerts.envelope.path | Should -Match '^artifacts/alerts/\d{8}T\d{6}Z\.graph\.json$'
            Join-Path $PSScriptRoot '..' $report.alerts.envelope.path | Should -Exist
            $report.alerts.envelope.valid | Should -BeTrue
        }

        It 'keeps artifacts/alerts/latest.graph.json a copy of the newest layer, for the portal' {
            $report.alerts.envelope.latest | Should -Be 'artifacts/alerts/latest.graph.json'
            $latest = Join-Path $PSScriptRoot '..' $report.alerts.envelope.latest
            $latest | Should -Exist
            $report.alerts.envelope.latestIsNewest | Should -BeTrue
            $stamped = Get-ChildItem (Split-Path $latest) -Filter '*.graph.json' | Where-Object Name -ne 'latest.graph.json' | Sort-Object Name | Select-Object -Last 1
            (Get-FileHash $latest).Hash | Should -Be (Get-FileHash $stamped.FullName).Hash
            (Get-Content $latest -Raw | ConvertFrom-Json).layer.ToUniversalTime().ToString('yyyyMMdd''T''HHmmss''Z''') + '.graph.json' | Should -Be $stamped.Name
        }

        It 'both files pass graphnode validate --ontology with the ontology Claude.Agent.Alerts ships: []' {
            $report.alerts.envelope.ontology | Should -Be 'build/host-modules/Claude.Agent.Alerts/ontology.yaml'
            @($report.alerts.envelope.validate) | Should -HaveCount 2
            foreach ($v in $report.alerts.envelope.validate) {
                $v.exitCode | Should -Be 0 -Because $v.path
                ($v.output -replace '\s', '') | Should -Be '[]' -Because $v.path
            }
        }

        It 'has a summary that matches its findings' {
            $report.alerts.total | Should -Be @($report.alerts.findings).Count
            $report.alerts.bySeverity.info + $report.alerts.bySeverity.warn + $report.alerts.bySeverity.error | Should -Be $report.alerts.total
            $report.alerts.bySeverity.error | Should -Be @($report.alerts.errors).Count
        }

        It 'raised exactly one error, the policy.deny of the smoke prompt''s delete' -Skip:(-not $hasAuth) {
            @($report.alerts.errors) | Should -HaveCount 1
            $e = @($report.alerts.errors)[0]
            $e.rule | Should -Be 'policy-deny'
            $e.kind | Should -Be 'policy.deny'
            $e.kindAction | Should -Be 'File.delete'
            $e.path | Should -Be $report.policy.smokeFile
            $e.id | Should -Be "alert:policy-deny:$($e.seq)"
        }

        It 'raised no error on a probe run' -Skip:$hasAuth {
            @($report.alerts.errors) | Should -HaveCount 0
        }

        It 'the envelope holds one Finding per finding and one raised-by edge each' {
            $g = Get-Content (Join-Path $PSScriptRoot '..' $report.alerts.envelope.path) -Raw | ConvertFrom-Json
            $g.module | Should -Be 'Claude.Agent.Alerts'
            @($g.nodes | Where-Object kind -eq 'Finding') | Should -HaveCount $report.alerts.total
            @($g.edges | Where-Object kind -eq 'raised-by') | Should -HaveCount $report.alerts.total
            $g.counts.nodes | Should -Be $report.alerts.envelope.nodes
            $g.counts.edges | Should -Be $report.alerts.envelope.edges
        }
    }
}
