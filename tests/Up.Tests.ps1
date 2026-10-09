# Up (design 11): the helpers in tools/Up.ps1 without Docker, then the record of the real run, artifacts/up.json.

BeforeDiscovery {
    $upPath = Join-Path $PSScriptRoot '../artifacts/up.json'
    $up = if (Test-Path $upPath) { Get-Content $upPath -Raw | ConvertFrom-Json -DateKind String } else { $null }
    $exported = $up -and $up.export -and -not $up.export.PSObject.Properties['skipped']
    $posted = $exported -and $up.export.portal.posted
}

BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'tools/Up.ps1')

    # A port nothing listens on: bind an ephemeral one, note it, let it go.
    function Get-ClosedPort {
        $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p
    }
}

Describe 'Format-AgentRunLine' {
    It 'prints the one line the other Up tasks print' {
        Format-AgentRunLine -Stamp '2026-10-09T08:00:00Z' -Url 'http://127.0.0.1:8200/' -Nodes 12 -Edges 11 |
            Should -BeExactly 'agent run 2026-10-09T08:00:00Z at http://127.0.0.1:8200/ (12 nodes, 11 edges)'
    }
}

Describe 'Send-PortalLayer' {
    It 'returns a warning and does not throw when nothing listens on the port' {
        $port = Get-ClosedPort
        $r = Send-PortalLayer -Url "http://127.0.0.1:$port" -Name 'agent-runs' -Path 'artifacts/layers/x.runs.graph.json'
        $r.Posted | Should -BeFalse
        $r.Warning | Should -BeExactly "portal not up on $port"
        $r.Url | Should -Be "http://127.0.0.1:$port/"
    }

    Context 'against a listener that answers' {
        BeforeAll {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $port = $listener.LocalEndpoint.Port
            # Answers the first connection that sends a request (the port probe sends nothing) with $status.
            $serve = {
                param($listener, [int] $status)
                $deadline = [datetime]::UtcNow.AddSeconds(20)
                while ([datetime]::UtcNow -lt $deadline) {
                    $client = $listener.AcceptTcpClient()
                    try {
                        $stream = $client.GetStream()
                        $stream.ReadTimeout = 2000
                        $buffer = [byte[]]::new(65536)
                        $text = ''
                        try {
                            while ($true) {
                                $n = $stream.Read($buffer, 0, $buffer.Length)
                                if ($n -le 0) { break }
                                $text += [Text.Encoding]::UTF8.GetString($buffer, 0, $n)
                                $head, $body = $text -split "`r`n`r`n", 2
                                if ($null -ne $body -and $head -match '(?im)^Content-Length:\s*(\d+)' -and [Text.Encoding]::UTF8.GetByteCount($body) -ge [int]$Matches[1]) { break }
                            }
                        }
                        catch { }
                        if (-not $text) { continue }
                        $json = '{"name":"agent-runs","counts":{"nodes":3,"edges":2}}'
                        $reply = "HTTP/1.1 $status X`r`nContent-Type: application/json`r`nContent-Length: $($json.Length)`r`nConnection: close`r`n`r`n$json"
                        $bytes = [Text.Encoding]::UTF8.GetBytes($reply)
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                        return $text
                    }
                    finally { $client.Dispose() }
                }
            }
        }
        AfterAll { $listener.Stop() }

        It 'POSTs {name, path} to /api/layers, path the layers folder, and returns the response' {
            $job = Start-ThreadJob -ScriptBlock $serve -ArgumentList $listener, 201
            $layer = Join-Path $TestDrive 'artifacts' 'layers'
            $r = Send-PortalLayer -Url "http://127.0.0.1:$port" -Name 'agent-runs' -Path $layer
            $request = $job | Wait-Job -Timeout 20 | Receive-Job
            $r.Posted | Should -BeTrue
            $r.Warning | Should -BeNullOrEmpty
            $r.Response.counts.nodes | Should -Be 3
            $request | Should -Match '^POST /api/layers HTTP/1\.1'
            $sent = ($request -split "`r`n`r`n", 2)[1] | ConvertFrom-Json
            $sent.name | Should -BeExactly 'agent-runs'
            $sent.path | Should -BeExactly ([IO.Path]::GetFullPath($layer))
            $sent.path | Should -Not -Match '\.graph\.json$'
        }

        It 'is called by Up with the layers folder, not the timestamped file' {
            $build = Get-Content -LiteralPath (Join-Path $root '.build.ps1') -Raw
            $build | Should -Match 'Send-PortalLayer -Url \$PortalUrl -Name \$PortalLayerName -Path \$layersDir\s'
            $build | Should -Not -Match 'Send-PortalLayer[^\r\n]*-Path \$layerFile'
        }

        It 'throws when the portal answers and refuses the layer' {
            $job = Start-ThreadJob -ScriptBlock $serve -ArgumentList $listener, 422
            { Send-PortalLayer -Url "http://127.0.0.1:$port" -Name 'agent-runs' -Path 'x' } | Should -Throw '*-> 422*'
            $job | Wait-Job -Timeout 20 | Remove-Job -Force
        }
    }
}

Describe 'Invoke-StackUp' {
    BeforeEach {
        $calls = [Collections.Generic.List[string]]::new()
        $stamps = [Collections.Generic.Queue[object]]::new()
        $stackArgs = @{
            GetStamp = { $calls.Add('stamp'); $stamps.Dequeue() }
            Down     = { $calls.Add('down') }
            WaitGone = { $calls.Add('wait') }
            Start    = { $calls.Add('start') }
        }
    }

    It 'starts a stack that is not up, and replaces nothing' {
        $stamps.Enqueue($null); $stamps.Enqueue('2026-10-09T08:00:00Z')
        $r = Invoke-StackUp @stackArgs
        $calls -join ',' | Should -Be 'stamp,start,stamp'
        $r.Replaced | Should -BeNullOrEmpty
        $r.Stamp | Should -Be '2026-10-09T08:00:00Z'
    }

    It 'brings a running stack down, waits, brings it up, and returns both stamps' {
        $stamps.Enqueue('2026-10-09T07:00:00Z'); $stamps.Enqueue('2026-10-09T08:00:00Z')
        $r = Invoke-StackUp @stackArgs
        $calls -join ',' | Should -Be 'stamp,down,wait,start,stamp'
        $r.Replaced | Should -Be '2026-10-09T07:00:00Z'
        $r.Stamp | Should -Be '2026-10-09T08:00:00Z'
    }

    It 'with -NoReplace throws on a running stack and touches nothing' {
        $stamps.Enqueue('2026-10-09T07:00:00Z')
        { Invoke-StackUp @stackArgs -Label 'compose project p' -NoReplace } | Should -Throw 'compose project p is up (since 2026-10-09T07:00:00Z)*'
        $calls -join ',' | Should -Be 'stamp'
    }

    It 'with -NoReplace starts a stack that is not up' {
        $stamps.Enqueue($null); $stamps.Enqueue('2026-10-09T08:00:00Z')
        (Invoke-StackUp @stackArgs -NoReplace).Stamp | Should -Be '2026-10-09T08:00:00Z'
        $calls -join ',' | Should -Be 'stamp,start,stamp'
    }
}

Describe 'Get-StackStamp' {
    BeforeAll {
        function New-Container([string] $Service, [bool] $Running, [string] $StartedAt) {
            [pscustomobject]@{
                State  = [pscustomobject]@{ Running = $Running; StartedAt = $StartedAt }
                Config = [pscustomobject]@{ Labels = [pscustomobject]@{ 'com.docker.compose.service' = $Service } }
            }
        }
    }

    It 'is null when no container is running' {
        Get-StackStamp -Containers @((New-Container agent $false '2026-10-09T07:00:00.123456789Z')) | Should -BeNullOrEmpty
        Get-StackStamp -Containers @() | Should -BeNullOrEmpty
    }

    It "is the agent container's start, even after the agent exited, while the sidecars run" {
        $c = (New-Container mitm $true '2026-10-09T06:59:58.5Z'), (New-Container agent $false '2026-10-09T07:00:01.987654321Z')
        Get-StackStamp -Containers $c | Should -Be '2026-10-09T07:00:01Z'
    }

    It 'falls back to the earliest running container when the agent never started' {
        $c = (New-Container ledger $true '2026-10-09T06:59:59Z'), (New-Container mitm $true '2026-10-09T06:59:58Z'), (New-Container agent $false '0001-01-01T00:00:00Z')
        Get-StackStamp -Containers $c | Should -Be '2026-10-09T06:59:58Z'
    }
}

Describe 'entrypoint and compose (Ledger 0.2.4 handoff)' {
    BeforeAll {
        $entry = Get-Content -LiteralPath (Join-Path $root 'entrypoint.ps1')
        $at = { param($pattern) for ($i = 0; $i -lt $entry.Count; $i++) { if ($entry[$i] -match $pattern) { return $i } }; -1 }
    }

    It 'snapshots right after the egress-check entry, before the exit on a failed check' {
        $check = & $at "-Kind 'agent.egress-check'"
        $snap = & $at '^Add-SnapshotEntry -At agent\.egress-check$'
        $exit = & $at '^if \(-not \$directBlocked\)'
        $check | Should -BeGreaterThan -1
        $snap | Should -BeGreaterThan $check
        $snap | Should -BeLessThan $exit
        @($entry[($check + 1)..($snap - 1)] | Where-Object { $_ -match 'Add-LedgerEntry' }) | Should -BeNullOrEmpty
    }

    It 'snapshots just before agent.stop' {
        $snap = & $at '^Add-SnapshotEntry -At agent\.stop$'
        $stop = & $at "-Kind 'agent.stop'"
        $snap | Should -BeGreaterThan -1
        $stop | Should -Be ($snap + 1)
    }

    It 'compose hands the agent CLAUDE_AGENT_IMAGE_DIGEST' {
        Get-Content -LiteralPath (Join-Path $root 'compose.yaml') -Raw | Should -Match 'CLAUDE_AGENT_IMAGE_DIGEST: \$\{CLAUDE_AGENT_IMAGE_DIGEST:-\}'
    }
}

Describe 'Up record (artifacts/up.json)' {
    BeforeAll {
        $upPath = Join-Path $root 'artifacts/up.json'
        $up = if (Test-Path $upPath) { Get-Content $upPath -Raw | ConvertFrom-Json -DateKind String } else { $null }
        $smokePath = Join-Path $root 'artifacts/smoke-report.json'
        $smoke = if (Test-Path $smokePath) { Get-Content $smokePath -Raw | ConvertFrom-Json -DateKind String } else { $null }
        $stampRule = '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
    }

    It 'exists' {
        $upPath | Should -Exist
    }

    It 'recorded the image digest it handed the agent, and the agent exited 0' {
        $up.imageDigest | Should -Match '^sha256:[0-9a-f]{64}$'
        $up.agentExit | Should -Be 0
    }

    It 'wrote artifacts/policy.json before the run, byte for byte the policy agent.start recorded' {
        $file = Join-Path $root 'artifacts/policy.json'
        $file | Should -Exist
        $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $up.policy.sha256 | Should -Be $sha
        $smoke.ledger.policySha256 | Should -Be $sha
    }

    It 'stamped the stack, and the old one when it replaced it' {
        $up.stack.stamp | Should -Match $stampRule
        if ($up.stack.replaced) { $up.stack.replaced | Should -Match $stampRule; $up.stack.replaced | Should -Not -Be $up.stack.stamp }
    }

    Context 'export' -Skip:(-not $exported) {
        BeforeAll {
            $layerFile = Join-Path $root $up.export.path
            $graph = if (Test-Path -LiteralPath $layerFile) { Get-Content -LiteralPath $layerFile -Raw | ConvertFrom-Json -DateKind String } else { $null }
        }

        It 'wrote a Graph.Emitter.Agent runs layer under artifacts/layers, with its ontology beside it' {
            $up.export.path | Should -Match '^artifacts/layers/.+\.runs\.graph\.json$'
            $layerFile | Should -Exist
            Join-Path (Split-Path -Parent $layerFile) 'ontology.yaml' | Should -Exist
            $graph.module | Should -Be 'Graph.Emitter.Agent'
            $graph.layer | Should -Be $up.export.layer
        }

        It 'recorded the counts the layer holds' {
            $up.export.nodes | Should -Be $graph.counts.nodes
            $up.export.edges | Should -Be $graph.counts.edges
            $up.export.nodes | Should -BeGreaterThan 0
        }

        It 'roots the layer at the last run, which stopped' {
            $run = $graph.nodes | Where-Object id -eq $graph.root
            $run.kind | Should -Be 'Run'
            $run.properties.stopped | Should -BeTrue
        }

        It "gave every decision of the last run its rule text, from artifacts/policy.json" {
            $decisions = @($graph.nodes | Where-Object { $_.kind -eq 'PolicyDecision' -and $_.id -like "$($graph.root)/*" })
            $decisions | Should -Not -BeNullOrEmpty
            @($decisions | Where-Object { -not $_.properties.ruleText }) | Should -BeNullOrEmpty
        }

        It 'has no error findings (the export ran -Strict)' {
            @($graph.findings | Where-Object severity -eq 'error') | Should -BeNullOrEmpty
        }

        It 'printed the URL line when the portal took the layer' -Skip:(-not $posted) {
            $up.export.portal.url | Should -Be 'http://127.0.0.1:8200/'
            $up.export.line | Should -BeExactly "agent run $($up.export.layer) at http://127.0.0.1:8200/ ($($up.export.nodes) nodes, $($up.export.edges) edges)"
        }

        It 'recorded the warning instead when the portal was not up' -Skip:$posted {
            $up.export.portal.warning | Should -Be 'portal not up on 8200'
            $up.export.line | Should -BeNullOrEmpty
        }
    }
}
