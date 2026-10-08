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
            @($report.egress.agentNetworks) | Should -Be @('claude-agent-dev_inside')
            @($report.egress.insideServices) | Should -Be @('agent', 'mitm')
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

        It 'claude -p exited 0, replied ok, and recorded the auth it used' -Skip:(-not $hasAuth) {
            $report.ledger.outcome.auth | Should -Be $report.run.auth
            $report.ledger.outcome.exitCode | Should -Be 0
            $report.ledger.outcome.output | Should -Match '\bok\b'
        }
    }

    Context 'capture' {
        It 'has at least one flow to api.anthropic.com' {
            $report.capture.anthropicFlows | Should -BeGreaterOrEqual 1
            $report.capture.hosts | Should -Contain 'api.anthropic.com'
        }

        It 'saw the response, not just the tunnel' {
            @($report.capture.anthropic | Where-Object status).Count | Should -BeGreaterOrEqual 1
        }
    }
}
