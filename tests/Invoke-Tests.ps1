#Requires -Version 7.4
# Run with: pwsh -NoProfile -File tests/Invoke-Tests.ps1
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5.0

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config

# The totals, for the Runs task's Run node (design 10). artifacts/ exists whenever Smoke has run.
$artifacts = Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts'
if (Test-Path -LiteralPath $artifacts) {
    [ordered]@{
        finished = [DateTime]::UtcNow.ToString('o')
        result   = $result.Result
        passed   = $result.PassedCount
        failed   = $result.FailedCount
        skipped  = $result.SkippedCount
        total    = $result.TotalCount
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $artifacts 'pester.json') -Encoding utf8NoBOM
}
# What Run.Exit did: non-zero when anything failed, a block or a container included.
exit ($result.FailedCount + $result.FailedBlocksCount + $result.FailedContainersCount)
