# Builds the smoke run's run-report layer (design 10). Dot-sourced by .build.ps1 (Runs task) and the Pester tests.
# Needs GraphNode imported (New-GraphNode, New-GraphEdge, New-GraphEnvelope, Export-Graph).
# The shape is the run-report skill's (.claude/skills/run-report, copied from Graph): Kinds Run, Finding, Decision,
# NotRun, Touched; Run `reports` Finding, Decision, NotRun; Run `touched` Touched.

function ConvertTo-RunStamp([datetime] $When) {
    $When.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

<#
.SYNOPSIS
Writes <OutDir>/<yyyyMMddTHHmmssZ>.graph.json (the layer stamp, = FinishedAt), a copy as latest.graph.json, and the
run-report ontology beside them; returns the stamped file.
.PARAMETER Report
artifacts/smoke-report.json, parsed (-AsHashtable -DateKind String), after the Alerts task has added `alerts`.
.PARAMETER AlertsEnvelopePath
The alerts layer the Run links to by stamp (properties.alertsLayer); its Finding nodes become Findings here.
.PARAMETER TasksRun
The build tasks that completed in this invocation, in order. Chain tasks missing from it become NotRun.
.PARAMETER Pester
{passed, failed, skipped} from the Pester task, or $null when Pester did not run (totals are then 0).
.PARAMETER Touched
Repo-relative paths the run wrote, besides the three files this writes (which are added).
#>
function New-SmokeRunReport {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Report,
        [Parameter(Mandatory)] [string] $AlertsEnvelopePath,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Task,
        [Parameter(Mandatory)] [datetime] $StartedAt,
        [Parameter(Mandatory)] [datetime] $FinishedAt,
        [Parameter(Mandatory)] [string[]] $TasksRun,
        [Parameter(Mandatory)] [string[]] $ChainTasks,
        [Parameter(Mandatory)] [string[]] $ImageDecision,
        [AllowNull()] $Pester,
        [string[]] $Touched = @(),
        [Parameter(Mandatory)] [string] $OutDir,
        [Parameter(Mandatory)] [string] $OntologyPath
    )

    $started = ConvertTo-RunStamp $StartedAt
    $finished = ConvertTo-RunStamp $FinishedAt
    $repo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/').Replace('\', '/')
    $runId = "run:$(Split-Path -Leaf $repo):$started"
    $alerts = Get-Content -LiteralPath $AlertsEnvelopePath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $auth = $Report.run.auth

    $runProps = [ordered]@{
        repo           = $repo
        task           = $Task
        startedAt      = $started
        finishedAt     = $finished
        buildResult    = 'succeeded'
        pesterPassed   = if ($Pester) { [int]$Pester.passed } else { 0 }
        pesterFailed   = if ($Pester) { [int]$Pester.failed } else { 0 }
        pesterSkipped  = if ($Pester) { [int]$Pester.skipped } else { 0 }
        project        = $Report.project
        tasks          = @($TasksRun)
        auth           = if ($auth) { $auth } else { 'probe' }
        runPath        = $Report.run.path
        imageName      = $Report.image.name
        imageSizeBytes = [long]$Report.image.sizeBytes
        # The alerts layer this run produced, by its layer stamp; the portal joins the two layers on it (no edge yet).
        alertsLayer    = [string]$alerts.layer
        alertsModule   = [string]$alerts.module
    }
    $run = New-GraphNode -Id $runId -Kind Run -Name "Claude.Agent $($TasksRun -join ', ')" -Properties $runProps

    $findings = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($alerts.nodes | Where-Object { $_.kind -eq 'Finding' })) {
        $text = "alert $($a.id): $($a.properties.message)"
        if ($a.properties.detail) { $text += " ($($a.properties.detail))" }
        $findings.Add(@{ text = $text; severity = [string]$a.properties.severity; alert = [string]$a.id })
    }
    $egress = $Report.egress
    $findings.Add($(if ($egress.directBlocked) {
                @{ text = "egress check: the agent's direct route out is blocked (curl exit $($egress.curlExit)); it reaches api.anthropic.com only through mitm"; severity = 'info' }
            }
            else { @{ text = "egress check: the agent reached out without the proxy (curl exit $($egress.curlExit))"; severity = 'error' } }))
    $stray = @($Report.ports.stray)
    $published = @($Report.ports.published)
    $findings.Add($(if ($stray.Count) {
                @{ text = "published-port check: host ports other than the reserved $($Report.ports.reserved) are published: $(($stray | ForEach-Object { "$($_.service):$($_.hostPort)" }) -join ', ')"; severity = 'error' }
            }
            else {
                @{ text = "published-port check: $(if ($published.Count) { "only the reserved $($Report.ports.reserved) is published" } else { "no host port is published; $($Report.ports.reserved) stays reserved" })"; severity = 'info' }
            }))

    $decisions = @(
        @{ text = $(if ($auth) { "auth path: claude -p with $(if ($auth -eq 'oauth') { 'CLAUDE_CODE_OAUTH_TOKEN' } else { 'ANTHROPIC_API_KEY' }) ($auth), because that credential was present" }
                else { 'auth path: curl probe only, because no CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY was present' }); revisit = $false }
    ) + @($ImageDecision | ForEach-Object { @{ text = $_; revisit = $false } })

    $notRun = [System.Collections.Generic.List[object]]::new()
    foreach ($t in $ChainTasks) {
        if ($t -notin $TasksRun) { $notRun.Add(@{ text = "task $t"; reason = "not run in this invocation ($Task)" }) }
    }
    if ($Pester -and [int]$Pester.skipped -gt 0) {
        $other = if ($auth) { 'the probe path (no credential)' } else { 'the claude -p path (a credential)' }
        $notRun.Add(@{ text = "$($Pester.skipped) Pester test(s)"; reason = "skipped: they apply only to $other" })
    }

    $layerName = $FinishedAt.ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture) + '.graph.json'
    $outFull = [System.IO.Path]::GetFullPath($OutDir)
    $own = foreach ($leaf in $layerName, 'latest.graph.json', 'ontology.yaml') {
        [System.IO.Path]::GetRelativePath($RepoRoot, (Join-Path $outFull $leaf)).Replace('\', '/')
    }

    $nodes = [System.Collections.Generic.List[object]]::new()
    $edges = [System.Collections.Generic.List[object]]::new()
    $nodes.Add($run)
    $n = 0
    foreach ($f in $findings) {
        $n++
        $props = @{ text = $f.text; severity = $f.severity }
        if ($f.alert) { $props.alert = $f.alert }
        $node = New-GraphNode -Id "finding:$n" -Kind Finding -Name "finding $n" -Properties $props
        $nodes.Add($node); $edges.Add((New-GraphEdge -From $run -To $node -Kind reports))
    }
    $n = 0
    foreach ($d in $decisions) {
        $n++
        $node = New-GraphNode -Id "decision:$n" -Kind Decision -Name "decision $n" -Properties @{ text = $d.text; revisit = [bool]$d.revisit }
        $nodes.Add($node); $edges.Add((New-GraphEdge -From $run -To $node -Kind reports))
    }
    $n = 0
    foreach ($x in $notRun) {
        $n++
        $node = New-GraphNode -Id "notrun:$n" -Kind NotRun -Name "not run $n" -Properties @{ text = $x.text; reason = $x.reason }
        $nodes.Add($node); $edges.Add((New-GraphEdge -From $run -To $node -Kind reports))
    }
    # artifacts/ and build/ are gitignored, so nothing the run writes is ever staged.
    foreach ($path in @(@($Touched) + @($own) | Select-Object -Unique)) {
        $node = New-GraphNode -Id "touched:$path" -Kind Touched -Name $path -Properties @{ path = $path; staged = $false }
        $nodes.Add($node); $edges.Add((New-GraphEdge -From $run -To $node -Kind touched))
    }

    $ontologyVersion = [regex]::Match((Get-Content -LiteralPath $OntologyPath -Raw), '(?m)^version:\s*(\S+)').Groups[1].Value
    $envelope = New-GraphEnvelope -Module Graph.RunReport -Version $ontologyVersion -Layer $finished -Root $runId -Ontology 'ontology.yaml' -Nodes $nodes.ToArray() -Edges $edges.ToArray()
    New-Item -ItemType Directory -Path $outFull -Force | Out-Null
    Copy-Item -LiteralPath $OntologyPath -Destination (Join-Path $outFull 'ontology.yaml') -Force
    $file = Export-Graph $envelope -Path (Join-Path $outFull $layerName)
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $outFull 'latest.graph.json') -Force
    $file
}
