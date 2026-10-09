<#
.SYNOPSIS
End-to-end build for Claude.Agent (Invoke-Build).
.DESCRIPTION
Default chain: Modules, Image, Up, Smoke, Down, Pester.
Assumes the sibling repos Claude.Agent.Ledger and Claude.Agent.Network sit next to this one.
#>
param(
    [string] $Project = 'claude-agent-dev',
    [string] $ImageName = 'claude-agent:dev',
    [string] $LedgerImageName = 'claude-agent-ledger:dev'
)

$SiblingRoot = Split-Path -Parent $BuildRoot
$Siblings = 'Claude.Agent.Ledger', 'Claude.Agent.Network'
$ModulesDir = Join-Path $BuildRoot 'build/modules'
$Artifacts = Join-Path $BuildRoot 'artifacts'

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

# Synopsis: Copy each sibling's src/<Module> into build/modules (the image build context).
task Modules {
    remove $ModulesDir
    New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null
    foreach ($name in $Siblings) {
        $src = Join-Path $SiblingRoot "$name/src/$name"
        assert (Test-Path (Join-Path $src "$name.psd1")) "Sibling module missing: $src. Clone $name next to Claude.Agent."
        Copy-Item -Path $src -Destination $ModulesDir -Recurse
        print Green "copied $name"
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
    $datadogIntake = 'http-intake.logs.us5.datadoghq.com'

    $imageSize = [long](exec { docker image inspect $ImageName --format '{{.Size}}' })

    $report = [ordered]@{
        generated = [DateTime]::UtcNow.ToString('o')
        run       = [ordered]@{
            auth = $auth
            path = if ($auth) { 'run' } else { 'probe' }
            note = if ($auth) { "credential present (auth: $auth): claude -p must exit 0 and reply ok" }
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
            anthropic      = @($anthropic | Select-Object method, host, path, status, requestBytes, responseBytes, started, refused)
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
        assert ($outcome.body.output -match '\bok\b') "claude -p did not reply ok: $($outcome.body.output)"
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
    remove $ModulesDir, $Artifacts
}

task . Modules, Image, Up, Smoke, Down, Pester
