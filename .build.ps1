<#
.SYNOPSIS
End-to-end build for Claude.Agent (Invoke-Build).
.DESCRIPTION
Default chain: Modules, Image, Up, Smoke, Alerts, Down, Pester.
Assumes the sibling repos Claude.Agent.Ledger, Claude.Agent.Network, Claude.Agent.Policy and Claude.Agent.Alerts,
and Graph.Node, sit next to this one.
#>
param(
    [string] $Project = 'claude-agent-dev',
    [string] $ImageName = 'claude-agent:dev',
    [string] $LedgerImageName = 'claude-agent-ledger:dev'
)

$SiblingRoot = Split-Path -Parent $BuildRoot
$Siblings = 'Claude.Agent.Ledger', 'Claude.Agent.Network', 'Claude.Agent.Policy'
$ModulesDir = Join-Path $BuildRoot 'build/modules'
# Host-only modules (design 7): never copied into an image; .dockerignore keeps them out of the build context.
$HostModulesDir = Join-Path $BuildRoot 'build/host-modules'
$PolicyDir = Join-Path $BuildRoot 'build/policy'
$Artifacts = Join-Path $BuildRoot 'artifacts'
$VendoredOntology = Join-Path $BuildRoot 'vendor/Graph.Emitter.FileSystem/ontology.yaml'
# The prompt in entrypoint.ps1 writes this file and then tries to delete it; the policy must keep it.
$PolicySmokeFile = '/work/policy-smoke.txt'

# True when Compose will hand the agent a non-empty $Name: from the shell environment, else from .env
# (the same precedence as Compose interpolation). Only presence is checked; no value is printed, stored or written.
function Test-CredentialPresent([string] $Name) {
    if ([Environment]::GetEnvironmentVariable($Name)) { return $true }
    $envFile = Join-Path $BuildRoot '.env'
    if (-not (Test-Path -LiteralPath $envFile)) { return $false }
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match "^\s*(?:export\s+)?$Name\s*=\s*(.*)$") {
            if ($Matches[1].Trim().Trim('"', "'").Length -gt 0) { return $true }
        }
    }
    $false
}

# 'oauth' (CLAUDE_CODE_OAUTH_TOKEN, primary), 'apikey' (ANTHROPIC_API_KEY, fallback), or $null for the probe path.
# Both set is an error: the agent refuses to start, so fail here first with the same message.
function Get-AgentAuth {
    $oauth = Test-CredentialPresent CLAUDE_CODE_OAUTH_TOKEN
    $apikey = Test-CredentialPresent ANTHROPIC_API_KEY
    assert (-not ($oauth -and $apikey)) 'Both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are set; set one (OAuth for a subscription, API key otherwise).'
    if ($oauth) { 'oauth' } elseif ($apikey) { 'apikey' } else { $null }
}

function Get-ServiceContainer([string] $Service) {
    $id = exec { docker compose ps -a -q $Service }
    assert $id "$Service container not found"
    $id
}

# Synopsis: Copy each sibling's src/<Module> into build/modules, and the policy hooks into build/policy (the image build context); Alerts and GraphNode into build/host-modules.
task Modules {
    remove $ModulesDir, $PolicyDir, $HostModulesDir
    New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null
    foreach ($name in $Siblings) {
        $src = Join-Path $SiblingRoot "$name/src/$name"
        assert (Test-Path (Join-Path $src "$name.psd1")) "Sibling module missing: $src. Clone $name next to Claude.Agent."
        Copy-Item -Path $src -Destination $ModulesDir -Recurse
        print Green "copied $name"
    }

    # Policy: the schema goes inside the module (Test-Policy looks there); hooks and the settings fragment are
    # baked at /opt/agent/policy by the Dockerfile, which also generates policy.json.
    $policyRepo = Join-Path $SiblingRoot 'Claude.Agent.Policy'
    Copy-Item -Path (Join-Path $policyRepo 'schemas') -Destination (Join-Path $ModulesDir 'Claude.Agent.Policy') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $PolicyDir 'hooks') -Force | Out-Null
    Copy-Item -Path (Join-Path $policyRepo 'hooks/*.ps1') -Destination (Join-Path $PolicyDir 'hooks')
    Copy-Item -Path (Join-Path $policyRepo 'hooks/settings.json') -Destination $PolicyDir
    print Green 'copied Claude.Agent.Policy hooks and schema'

    # The image builds from the vendored ontology; say so when the emitter's copy has moved on.
    $upstream = Join-Path $SiblingRoot 'Graph.Emitter.FileSystem/ontology.yaml'
    if ((Test-Path $upstream) -and ((Get-FileHash $upstream).Hash -ne (Get-FileHash $VendoredOntology).Hash)) {
        print Yellow "vendor/Graph.Emitter.FileSystem/ontology.yaml differs from $upstream; recopy it if the change is wanted"
    }

    # Alerts runs on the host after Smoke, never in the agent image (design 7); it writes a GraphNode layer.
    New-Item -ItemType Directory -Path $HostModulesDir -Force | Out-Null
    foreach ($src in (Join-Path $SiblingRoot 'Claude.Agent.Alerts/src/Claude.Agent.Alerts'), (Join-Path $SiblingRoot 'Graph.Node/src/GraphNode')) {
        $name = Split-Path -Leaf $src
        assert (Test-Path (Join-Path $src "$name.psd1")) "Sibling module missing: $src. Clone it next to Claude.Agent."
        Copy-Item -Path $src -Destination $HostModulesDir -Recurse
        print Green "copied $name (host only)"
    }
}

# Synopsis: Build the agent and ledger keeper images.
task Image {
    exec { docker compose build agent ledger }
}

# Synopsis: Start mitm, ledger and agent, wait for the agent to exit, require exit 0.
task Up {
    $auth = Get-AgentAuth
    $path = if ($auth) { "run (auth: $auth; claude -p)" } else { 'probe (no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY: curl probe)' }
    print Cyan "run path: $path"
    exec { docker compose up -d --force-recreate }
    $id = Get-ServiceContainer agent
    $code = exec { docker wait $id }
    exec { docker compose logs --no-color agent }
    assert ($code -eq '0') "agent exited with $code"
}

# Synopsis: Drain the spool, pull the ledger and capture out, check isolation, write artifacts/smoke-report.json.
task Smoke {
    remove $Artifacts
    New-Item -ItemType Directory -Path $Artifacts -Force | Out-Null
    Import-Module (Join-Path $ModulesDir 'Claude.Agent.Ledger') -Force
    Import-Module (Join-Path $ModulesDir 'Claude.Agent.Network') -Force
    $auth = Get-AgentAuth
    $agentId = Get-ServiceContainer agent
    $keeperId = Get-ServiceContainer ledger

    # The agent only spools; wait for the keeper to chain everything, then stop it (SIGTERM flushes once more).
    exec { docker compose stop agent }
    $drainClock = [Diagnostics.Stopwatch]::StartNew()
    $drained = $false
    while ($drainClock.Elapsed.TotalSeconds -lt 30) {
        & docker compose exec -T ledger sh -c 'test ! -s /spool/pending.jsonl' 2>$null
        if ($LASTEXITCODE -eq 0) { $drained = $true; break }
        Start-Sleep -Milliseconds 500
    }
    $drainSeconds = [math]::Round($drainClock.Elapsed.TotalSeconds, 1)
    exec { docker compose stop ledger }
    $keeperExit = [int](exec { docker inspect $keeperId --format '{{.State.ExitCode}}' })

    # mitmdump buffers the stream file; stopping it flushes flows.mitm.
    exec { docker compose stop mitm }

    # Ledger: copy the volume out through a container that is created but never started.
    $ledgerDir = Join-Path $Artifacts 'ledger'
    $cid = exec { docker create --mount "type=volume,source=${Project}_ledger,target=/ledger" $LedgerImageName }
    try { exec { docker cp "${cid}:/ledger/." $ledgerDir } }
    finally { exec { docker rm $cid } | Out-Null }

    $ledgerError = $null
    try { $ledgerValid = Test-Ledger -Path $ledgerDir }
    catch { $ledgerValid = $false; $ledgerError = "$_" }
    # The key was only needed for Test-Ledger; do not leave it lying around on the host.
    Remove-Item (Join-Path $ledgerDir 'key.bin') -Force

    # A run begins with its egress check; take everything from the last one on.
    $entries = @(Get-Ledger -Path $ledgerDir)
    $lastCheck = [array]::FindLastIndex([object[]]$entries, [Predicate[object]] { param($e) $e.kind -eq 'agent.egress-check' })
    $lastRun = if ($lastCheck -ge 0) { @($entries[$lastCheck..($entries.Count - 1)]) } else { @() }
    $egress = $lastRun | Where-Object kind -eq 'agent.egress-check' | Select-Object -First 1
    $start = $lastRun | Where-Object kind -eq 'agent.start' | Select-Object -First 1
    $outcome = $lastRun | Where-Object kind -in 'agent.run', 'agent.probe' | Select-Object -Last 1

    # Isolation: no key.bin in the agent image, no ledger mount on the agent container, agent on `inside` only.
    $keyBinInImage = @(& docker run --rm --network none --entrypoint find $ImageName / -xdev -name key.bin 2>$null | Where-Object { $_ })
    $agentMounts = @(exec { docker inspect $agentId --format '{{json .Mounts}}' } | ConvertFrom-Json)
    $agentNetworks = @((exec { docker inspect $agentId --format '{{json .NetworkSettings.Networks}}' } | ConvertFrom-Json).PSObject.Properties.Name)
    $insideInternal = (exec { docker network inspect "${Project}_inside" --format '{{.Internal}}' }) -eq 'true'
    # -AsHashtable: the agent's environment has both HTTP_PROXY and http_proxy.
    $config = (exec { docker compose config --format json }) -join "`n" | ConvertFrom-Json -AsHashtable
    $insideServices = @($config.services.GetEnumerator() |
        Where-Object { $_.Value['networks'] -and $_.Value['networks'].Contains('inside') } |
        ForEach-Object Key | Sort-Object)

    # Capture: convert straight off the volume with the sidecar's image.
    $captureJson = Join-Path $Artifacts 'capture.json'
    ConvertTo-NetworkCapture -Volume "${Project}_capture" -FlowsPath 'flows.mitm' -OutPath $captureJson | Out-Null
    $flows = @(Get-NetworkCapture -Path $captureJson)
    $captureSummary = Get-NetworkCapture -Path $captureJson -Summary
    $allowedHosts = @($flows | Where-Object { -not $_.refused } | ForEach-Object host | Sort-Object -Unique)
    $anthropic = @($flows | Where-Object host -eq 'api.anthropic.com')
    $allowed = @($flows | Where-Object { -not $_.refused })
    $datadogIntake = 'http-intake.logs.us5.datadoghq.com'

    # Policy: what the image baked, who owns it, and what the hooks decided in the last run.
    $policy = (exec { docker run --rm --network none --entrypoint cat $ImageName /opt/agent/policy/policy.json }) -join "`n" | ConvertFrom-Json
    $policyFiles = @(exec { docker run --rm --network none --entrypoint find $ImageName /opt/agent/policy -printf '%u:%g %m %p\n' } |
        Where-Object { $_ } | ForEach-Object {
            $owner, $mode, $path = $_ -split ' ', 3
            [ordered]@{ path = $path; owner = $owner; mode = $mode; writable = ([Convert]::ToInt32($mode, 8) -band 0x92) -ne 0 }
        })
    $decisions = @($lastRun | Where-Object { $_.kind -like 'policy.*' } | ForEach-Object {
        [ordered]@{
            kind = $_.kind; phase = $_.body.phase; tool = $_.body.tool; kindAction = $_.body.kindAction
            path = $_.body.path; rule = $_.body.rule; command = $_.body.command
        }
    })
    $pre = @($decisions | Where-Object phase -eq 'pre')
    # The prompt's three steps must show up, in order, among the pre-call decisions.
    $expected = @(@('policy.allow', 'File.read'), @('policy.allow', 'File.write'), @('policy.deny', 'File.delete'))
    $matched = 0
    $denyAt = -1
    for ($i = 0; $i -lt $pre.Count -and $matched -lt 3; $i++) {
        if ($pre[$i].kind -eq $expected[$matched][0] -and $pre[$i].kindAction -eq $expected[$matched][1]) {
            if ($matched -eq 2) { $denyAt = $i }
            $matched++
        }
    }
    $afterDeny = @(if ($denyAt -ge 0) { $pre | Select-Object -Skip ($denyAt + 1) })
    # Independent of anything the agent recorded: copy the file out of the stopped container.
    $smokeCopy = Join-Path $Artifacts 'policy-smoke.txt'
    & docker cp "${agentId}:$PolicySmokeFile" $smokeCopy 2>$null | Out-Null
    $smokeFileExists = $LASTEXITCODE -eq 0

    $imageSize = [long](exec { docker image inspect $ImageName --format '{{.Size}}' })

    $report = [ordered]@{
        generated = [DateTime]::UtcNow.ToString('o')
        run       = [ordered]@{
            auth = $auth
            path = if ($auth) { 'run' } else { 'probe' }
            note = if ($auth) { "credential present (auth: $auth): claude -p must exit 0, end its reply with ok, and leave the policy decisions in the ledger" }
                   else { 'no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY in .env or the environment: curl probe only; the claude -p assertion is skipped' }
        }
        image     = [ordered]@{ name = $ImageName; sizeBytes = $imageSize; sizeMB = [math]::Round($imageSize / 1MB, 1) }
        egress    = [ordered]@{
            directBlocked  = if ($egress) { [bool]$egress.body.directBlocked } else { $null }
            curlExit       = if ($egress) { $egress.body.curlExit } else { $null }
            agentNetworks  = $agentNetworks
            insideInternal = $insideInternal
            insideServices = $insideServices
        }
        isolation = [ordered]@{
            agentImageKeyBin    = $keyBinInImage
            agentMounts         = @($agentMounts | ForEach-Object { [ordered]@{ name = $_.Name; destination = $_.Destination; rw = $_.RW } })
            agentHasLedgerMount = @($agentMounts | Where-Object { $_.Destination -eq '/ledger' -or $_.Name -eq "${Project}_ledger" }).Count -gt 0
        }
        keeper    = [ordered]@{ drained = $drained; drainSeconds = $drainSeconds; exitCode = $keeperExit }
        ledger    = [ordered]@{
            valid         = $ledgerValid
            error         = $ledgerError
            totalEntries  = $entries.Count
            lastRunKinds  = @($lastRun.kind)
            mode          = if ($outcome) { $outcome.kind } else { $null }
            outcome       = if ($outcome) { $outcome.body } else { $null }
            claudeVersion = if ($start) { $start.body.claudeVersion } else { $null }
        }
        capture   = [ordered]@{
            flows          = $flows.Count
            anthropicFlows = $anthropic.Count
            hosts          = @($flows.host | Sort-Object -Unique)
            allowedHosts   = $allowedHosts
            refusedHosts   = @($captureSummary.refusedHosts)
            summary        = [ordered]@{
                allowed      = $captureSummary.allowed
                refused      = $captureSummary.refused
                refusedHosts = @($captureSummary.refusedHosts)
            }
            refused        = @($flows | Where-Object refused | Select-Object method, host, path, status, started)
            allowed        = @($allowed | Select-Object method, host, path, status, requestBytes, responseBytes, started)
        }
        policy    = [ordered]@{
            generated       = $policy.generated
            default         = $policy.default
            rules           = @($policy.rules)
            files           = $policyFiles
            decisions       = $decisions
            preSequence     = @($pre | ForEach-Object { "$($_.kind) $($_.kindAction)" })
            sequenceMatched = $matched -eq 3
            afterDeny       = @($afterDeny)
            smokeFile       = $PolicySmokeFile
            smokeFileExists = $smokeFileExists
        }
    }
    $reportPath = Join-Path $Artifacts 'smoke-report.json'
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $reportPath -Encoding utf8NoBOM
    print Cyan (Get-Content $reportPath -Raw)

    assert $drained 'the keeper did not drain /spool/pending.jsonl within 30 s'
    assert ($keeperExit -eq 0) "the ledger keeper exited with $keeperExit on SIGTERM"
    assert $ledgerValid "Test-Ledger failed: $ledgerError"
    assert ($lastRun.kind -contains 'agent.start') 'no agent.start in the ledger'
    assert ($lastRun.kind -contains 'agent.stop') 'last run has no agent.stop'
    assert ($report.egress.directBlocked -eq $true) 'the agent reached api.anthropic.com without the proxy'
    assert $insideInternal "network ${Project}_inside is not internal"
    assert (($agentNetworks -join ',') -eq "${Project}_inside") "agent networks: $($agentNetworks -join ', ')"
    assert (($insideServices -join ',') -eq 'agent,mitm') "services on inside: $($insideServices -join ', ')"
    assert ($keyBinInImage.Count -eq 0) "key.bin in the agent image: $($keyBinInImage -join ', ')"
    assert (-not $report.isolation.agentHasLedgerMount) 'the agent container has a /ledger mount'
    assert $outcome 'last run has neither agent.run nor agent.probe'
    if ($auth) {
        assert ($outcome.kind -eq 'agent.run') "a credential is present (auth: $auth) but the last run was $($outcome.kind)"
        assert ($outcome.body.auth -eq $auth) "agent.run recorded auth '$($outcome.body.auth)', expected '$auth'"
        assert ($outcome.body.exitCode -eq 0) "claude -p exited $($outcome.body.exitCode): $($outcome.body.output)"
        # The last line, not anywhere: a reply saying it is "not replying ok" must fail.
        $lastLine = @(($outcome.body.output -split "`n") | Where-Object { $_.Trim() })[-1]
        assert ($lastLine -match '^\W*ok\W*$') "claude -p did not end its reply with ok: $($outcome.body.output)"
    }
    else {
        assert ($outcome.kind -eq 'agent.probe') "no credential is present but the last run was $($outcome.kind)"
    }
    assert ($anthropic.Count -ge 1) "no flow to api.anthropic.com in the capture (hosts: $($flows.host -join ', '))"
    # Egress allowlist (Claude.Agent.Network design 4): only api.anthropic.com gets through; the rest is refused and recorded.
    assert (($allowedHosts -join ',') -eq 'api.anthropic.com') "allowed hosts: $($allowedHosts -join ', ')"
    if ($auth) {
        # Claude Code's telemetry; the probe path runs only curl, so there is nothing to refuse there.
        assert ($report.capture.refusedHosts -contains $datadogIntake) "$datadogIntake not among refused hosts: $($report.capture.refusedHosts -join ', ')"
    }
    # Policy (Claude.Agent.Policy): baked root-owned and read-only; on a claude -p run, read and write allowed, delete denied.
    assert (@($policy.rules).Count -gt 0) 'the baked policy has no rules'
    $loose = @($policyFiles | Where-Object { $_.owner -ne 'root:root' -or $_.writable })
    assert ($loose.Count -eq 0) "policy files not root-owned read-only: $(($loose | ForEach-Object { "$($_.path) $($_.owner) $($_.mode)" }) -join '; ')"
    if ($auth) {
        assert ($matched -eq 3) "policy decisions do not hold allow File.read, allow File.write, deny File.delete in order: $($report.policy.preSequence -join ' | ')"
        assert $smokeFileExists "$PolicySmokeFile is gone: the denied delete happened anyway"
        $ranDenied = @($decisions | Where-Object { $_.phase -eq 'post' -and $_.kind -eq 'policy.deny' })
        assert ($ranDenied.Count -eq 0) "a call the policy denies ran: $(($ranDenied | ForEach-Object { "$($_.tool) $($_.kindAction) $($_.path)" }) -join '; ')"
    }
}

# Synopsis: Run Claude.Agent.Alerts over the last run in the copied ledger; write artifacts/alerts/<stamp>.graph.json and add `alerts` to smoke-report.json.
task Alerts {
    $reportPath = Join-Path $Artifacts 'smoke-report.json'
    $ledgerFile = Join-Path $Artifacts 'ledger/ledger.jsonl'
    assert (Test-Path $reportPath) "no $reportPath; run Smoke first"
    Import-Module (Join-Path $HostModulesDir 'GraphNode') -Force
    Import-Module (Join-Path $HostModulesDir 'Claude.Agent.Alerts') -Force

    # The ledger keeps every run until Clean; alert on the last one, which begins with its egress check (as Smoke reads it).
    $lastCheck = Get-Content -LiteralPath $ledgerFile | ConvertFrom-Json | Where-Object kind -eq 'agent.egress-check' | Select-Object -Last 1
    $fromSeq = if ($lastCheck) { [long]$lastCheck.seq } else { $null }
    $findings = @(Invoke-LedgerAlert -LedgerPath $ledgerFile -FromSeq $fromSeq)
    $file = Export-LedgerAlert -Findings $findings -OutDir (Join-Path $Artifacts 'alerts') -LedgerPath $ledgerFile
    $check = Test-Graph -Path $file.FullName -Strict
    $graph = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
    $summary = Get-LedgerAlertSummary -Findings $findings
    $errors = @($findings | Where-Object severity -eq 'error')

    # -DateKind String: keep the report's stamps exactly as Smoke wrote them.
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $report.alerts = [ordered]@{
        fromSeq    = $fromSeq
        total      = $summary.total
        bySeverity = $summary.bySeverity
        byRule     = $summary.byRule
        errors     = @($errors | ForEach-Object {
                [ordered]@{ id = $_.id; rule = $_.rule; seq = $_.seq; kind = $_.kind; kindAction = $_.kindAction; path = $_.path; command = $_.command; message = $_.message }
            })
        findings   = @($findings | ForEach-Object { [ordered]@{ id = $_.id; severity = $_.severity; kind = $_.kind; detail = $_.detail } })
        envelope   = [ordered]@{
            path  = [System.IO.Path]::GetRelativePath($BuildRoot, $file.FullName).Replace('\', '/')
            valid = $check.Valid
            nodes = $graph.counts.nodes
            edges = $graph.counts.edges
        }
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path $reportPath -Encoding utf8NoBOM
    print Cyan ($report.alerts | ConvertTo-Json -Depth 6)

    assert $check.Valid "alerts envelope is not valid: $(($check.Problems | ForEach-Object { "$($_.Code) $($_.Path): $($_.Message)" }) -join '; ')"
    if ($report.run.auth) {
        # The smoke prompt's delete is the one thing a clean claude -p run should be refused.
        assert ($errors.Count -eq 1) "expected exactly one error finding (the smoke delete's policy.deny), got $($errors.Count): $(($errors | ForEach-Object { "$($_.id) $($_.detail)" }) -join '; ')"
        assert ($errors[0].rule -eq 'policy-deny' -and $errors[0].kindAction -eq 'File.delete' -and $errors[0].path -eq $PolicySmokeFile) "the one error is not the smoke delete's deny: $($errors[0].id) $($errors[0].kindAction) $($errors[0].path)"
    }
    else {
        assert ($errors.Count -eq 0) "the probe run raised errors: $(($errors | ForEach-Object id) -join ', ')"
    }
}

# Synopsis: Stop and remove containers; volumes are kept.
task Down {
    exec { docker compose down }
}

# Synopsis: Assert the smoke report with Pester (the record of the run).
task Pester {
    exec { pwsh -NoProfile -File "$BuildRoot/tests/Invoke-Tests.ps1" }
}

# Synopsis: Remove containers, volumes (spool, ledger, CA, capture), build/ and artifacts/.
task Clean {
    exec { docker compose down --volumes }
    remove $ModulesDir, $PolicyDir, $HostModulesDir, $Artifacts
}

task . Modules, Image, Up, Smoke, Alerts, Down, Pester
