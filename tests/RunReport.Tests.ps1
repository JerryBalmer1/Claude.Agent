# The run-report layer (design 10), built from this run's artifacts/smoke-report.json and alerts layer with the
# same function the Runs task uses. The Runs task runs after Pester (it needs Pester's totals), so these tests
# build their own layer in TestDrive rather than read artifacts/runs/.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $artifacts = Join-Path $repo 'artifacts'
    $ontology = Join-Path $repo '.claude/skills/run-report/reference/ontology.yaml'
    $graphnode = Join-Path $repo ('build/host-modules/GraphNode/bin/' + $(if ($IsWindows) { 'win-x64/graphnode.exe' } else { 'linux-x64/graphnode' }))
    Import-Module (Join-Path $repo 'build/host-modules/GraphNode') -Force
    . (Join-Path $repo 'tools/RunReport.ps1')

    $report = Get-Content (Join-Path $artifacts 'smoke-report.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $alertsPath = Join-Path $artifacts 'alerts/latest.graph.json'
    $alerts = Get-Content $alertsPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $started = [datetime]::new(2026, 10, 9, 2, 0, 0, [DateTimeKind]::Utc)
    $finished = $started.AddMinutes(1)
    $outDir = Join-Path $artifacts "runs-test-$([guid]::NewGuid())"
    $file = New-SmokeRunReport -Report $report -AlertsEnvelopePath $alertsPath -RepoRoot $repo `
        -Task 'Invoke-Build Smoke, Alerts, Pester' -StartedAt $started -FinishedAt $finished `
        -TasksRun 'Smoke', 'Alerts', 'Pester' -ChainTasks 'Modules', 'Image', 'Up', 'Smoke', 'Alerts', 'Down', 'Pester' `
        -ImageDecision 'image claude-agent:dev: used as it was', 'image claude-agent-ledger:dev: used as it was' `
        -Pester @{ passed = 30; failed = 0; skipped = 2 } -Touched 'artifacts/smoke-report.json' -OutDir $outDir -OntologyPath $ontology
    $g = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $byKind = $g.nodes | Group-Object { $_.kind } -AsHashTable -AsString
}

AfterAll {
    if ($outDir -and (Test-Path $outDir)) { Remove-Item $outDir -Recurse -Force }
}

Describe 'Run report layer' {
    It 'is a Graph.RunReport envelope named by its layer stamp, with latest.graph.json a copy' {
        $file.Name | Should -Be '20261009T020100Z.graph.json'
        $g.module | Should -Be 'Graph.RunReport'
        $g.layer | Should -Be '2026-10-09T02:01:00Z'
        $g.ontology | Should -Be 'ontology.yaml'
        $g.root | Should -Be 'run:Claude.Agent:2026-10-09T02:00:00Z'
        (Get-FileHash (Join-Path $outDir 'latest.graph.json')).Hash | Should -Be (Get-FileHash $file.FullName).Hash
        Join-Path $outDir 'ontology.yaml' | Should -Exist
    }

    It 'validates with graphnode validate --ontology against the run-report ontology: []' {
        $out = & $graphnode validate $file.FullName --ontology $ontology
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        ($out -join '') -replace '\s', '' | Should -Be '[]'
    }

    It 'has one Run with the ontology''s required properties and the build''s facts' {
        @($byKind['Run']) | Should -HaveCount 1
        $p = $byKind['Run'][0].properties
        foreach ($k in 'repo', 'task', 'startedAt', 'finishedAt', 'buildResult', 'pesterPassed', 'pesterFailed', 'pesterSkipped') { $p.Contains($k) | Should -BeTrue -Because $k }
        $p.repo | Should -Be ($repo.Replace('\', '/'))
        $p.pesterPassed | Should -Be 30
        $p.imageSizeBytes | Should -Be $report.image.sizeBytes
        $p.auth | Should -Be $(if ($report.run.auth) { $report.run.auth } else { 'probe' })
        @($p.tasks) | Should -Be @('Smoke', 'Alerts', 'Pester')
    }

    It 'carries the alerts layer stamp, and no edge into the alerts layer' {
        $byKind['Run'][0].properties.alertsLayer | Should -Be $alerts.layer
        foreach ($e in $g.edges) { $e.to | Should -Not -Match '^(alert|ledger):' }
    }

    It 'has a Finding per alert with the rule''s severity, then the egress and published-port checks' {
        $alertFindings = @($alerts.nodes | Where-Object { $_.kind -eq 'Finding' })
        $findings = @($byKind['Finding'] | Sort-Object { [int]($_.id -replace '^finding:') })
        $findings | Should -HaveCount ($alertFindings.Count + 2)
        for ($i = 0; $i -lt $alertFindings.Count; $i++) {
            $findings[$i].properties.alert | Should -Be $alertFindings[$i].id
            $findings[$i].properties.severity | Should -Be $alertFindings[$i].properties.severity
        }
        $findings[-2].properties.text | Should -BeLike 'egress check:*'
        $findings[-2].properties.severity | Should -Be $(if ($report.egress.directBlocked) { 'info' } else { 'error' })
        $findings[-1].properties.text | Should -BeLike 'published-port check:*'
        $findings[-1].properties.severity | Should -Be 'info'
    }

    It 'records the auth path and the image reuse as Decisions' {
        $texts = @($byKind['Decision'] | ForEach-Object { $_.properties.text })
        $texts[0] | Should -BeLike 'auth path:*'
        @($texts | Where-Object { $_ -like 'image *' }) | Should -HaveCount 2
        foreach ($d in $byKind['Decision']) { $d.properties.revisit | Should -BeOfType [bool] }
    }

    It 'has a NotRun per chain task this invocation skipped, and for skipped Pester tests' {
        $texts = @($byKind['NotRun'] | ForEach-Object { $_.properties.text })
        $texts | Should -Contain 'task Modules'
        $texts | Should -Contain 'task Down'
        $texts | Should -Not -Contain 'task Smoke'
        $texts | Should -Contain '2 Pester test(s)'
    }

    It 'has a Touched per file written, its own three included, every one existing and none staged' {
        $paths = @($byKind['Touched'] | ForEach-Object { $_.properties.path })
        $paths | Should -Contain 'artifacts/smoke-report.json'
        $paths | Should -Contain ([System.IO.Path]::GetRelativePath($repo, $file.FullName).Replace('\', '/'))
        foreach ($t in $byKind['Touched']) {
            Join-Path $repo $t.properties.path | Should -Exist
            $t.properties.staged | Should -BeFalse
            $t.id | Should -Be "touched:$($t.properties.path)"
        }
    }

    It 'links the Run to every other node: reports to Finding, Decision, NotRun; touched to Touched' {
        $runId = $byKind['Run'][0].id
        $others = @($g.nodes | Where-Object { $_.kind -ne 'Run' })
        @($g.edges) | Should -HaveCount $others.Count
        foreach ($n in $others) {
            $kind = if ($n.kind -eq 'Touched') { 'touched' } else { 'reports' }
            @($g.edges | Where-Object { $_.from -eq $runId -and $_.to -eq $n.id -and $_.kind -eq $kind }) | Should -HaveCount 1 -Because $n.id
        }
    }

    It 'uses ids in the run report''s registered shapes' {
        foreach ($n in $g.nodes) {
            $prefix = $n.id.Substring(0, $n.id.IndexOf(':'))
            Test-GraphId -Prefix $prefix -Id $n.id | Should -BeTrue -Because $n.id
        }
    }
}
