#Requires -Version 7.4
# Run with: pwsh -NoProfile -File tests/Invoke-Tests.ps1
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5.0

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
