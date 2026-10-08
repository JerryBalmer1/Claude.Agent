#Requires -Version 7.4
# Agent container entrypoint.
#   Phase 1 (root):  wait for the mitmproxy CA on /ca, add it to the system store, re-exec as `agent`.
#   Phase 2 (agent): check there is no direct route out, do one run (claude -p with a credential, a curl probe
#                    without), exit 0. Every step is written to the spool; the `ledger` sidecar chains it. This
#                    container never holds the ledger key and cannot read or verify the ledger.
# Credentials: CLAUDE_CODE_OAUTH_TOKEN (subscription) or ANTHROPIC_API_KEY, never both. Only which one is
# present is ever printed or ledgered, never a value.
$ErrorActionPreference = 'Stop'
$caPath = '/ca/mitmproxy-ca-cert.pem'
$spool = '/spool'

if ($env:CLAUDE_CODE_OAUTH_TOKEN -and $env:ANTHROPIC_API_KEY) {
    Write-Host 'Refusing to start: both CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY are set. Set one (OAuth for a subscription, API key otherwise).'
    exit 2
}
$auth = if ($env:CLAUDE_CODE_OAUTH_TOKEN) { 'oauth' } elseif ($env:ANTHROPIC_API_KEY) { 'apikey' } else { $null }
# Compose passes unset credentials as empty strings; drop them so Claude Code sees only the one in use.
foreach ($name in 'CLAUDE_CODE_OAUTH_TOKEN', 'ANTHROPIC_API_KEY') {
    if (-not [Environment]::GetEnvironmentVariable($name)) { [Environment]::SetEnvironmentVariable($name, $null) }
}

if ((& id -u) -eq '0') {
    $deadline = (Get-Date).AddMinutes(2)
    while (-not (Test-Path -LiteralPath $caPath)) {
        if ((Get-Date) -gt $deadline) { throw "mitmproxy CA did not appear at $caPath within 2 minutes." }
        Start-Sleep -Seconds 1
    }
    Copy-Item -LiteralPath $caPath -Destination /usr/local/share/ca-certificates/mitmproxy.crt -Force
    & update-ca-certificates --fresh *> $null
    if ($LASTEXITCODE -ne 0) { throw "update-ca-certificates failed with exit $LASTEXITCODE." }

    $env:HOME = '/home/agent'
    & setpriv --reuid=agent --regid=agent --init-groups pwsh -NoProfile -File $PSCommandPath
    exit $LASTEXITCODE
}

# Node keeps its own CA list; point it at the same cert the system store now trusts.
$env:NODE_EXTRA_CA_CERTS = $caPath

Import-Module Claude.Agent.Ledger

# The proxy env is a convenience. The control is the internal network: going direct must fail.
$direct = & curl --noproxy '*' -sS -m 5 https://api.anthropic.com/ 2>&1
$directExit = $LASTEXITCODE
$directBlocked = $directExit -ne 0
Add-LedgerEntry -Spool $spool -Kind 'agent.egress-check' -Body @{
    directBlocked = $directBlocked
    curlExit      = $directExit
    detail        = ($direct | Out-String).Trim()
} | Out-Null
if (-not $directBlocked) {
    Write-Host 'agent.egress-check FAILED: reached https://api.anthropic.com/ without the proxy'
    exit 3
}
Write-Host "agent.egress-check: direct route blocked (curl exit $directExit)"

$claudeVersion = (& claude --version 2>&1 | Out-String).Trim()
Add-LedgerEntry -Spool $spool -Kind 'agent.start' -Body @{
    claudeVersion = $claudeVersion
    hostname      = [System.Net.Dns]::GetHostName()
    user          = (& id -un)
    mode          = if ($auth) { 'run' } else { 'probe' }
    auth          = $auth
} | Out-Null

if ($auth) {
    $output = & claude -p 'Reply with the single word ok' --output-format text 2>&1
    $exitCode = $LASTEXITCODE
    Add-LedgerEntry -Spool $spool -Kind 'agent.run' -Body @{
        auth     = $auth
        exitCode = $exitCode
        output   = ($output | Out-String).Trim()
    } | Out-Null
    Write-Host "agent.run auth=$auth exit=$exitCode output=$(($output | Out-String).Trim())"
}
else {
    $url = 'https://api.anthropic.com/v1/models'
    $status = (& curl -sS --max-time 30 -o /dev/null -w '%{http_code}' $url 2>&1 | Out-String).Trim()
    $curlExit = $LASTEXITCODE
    Add-LedgerEntry -Spool $spool -Kind 'agent.probe' -Body @{
        url      = $url
        status   = $status
        curlExit = $curlExit
    } | Out-Null
    Write-Host "agent.probe $url -> $status (curl exit $curlExit)"
}

Add-LedgerEntry -Spool $spool -Kind 'agent.stop' -Body @{} | Out-Null
Write-Host 'agent.stop; entries spooled for the ledger keeper'
exit 0
