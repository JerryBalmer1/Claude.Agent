#Requires -Version 7.4
# Helpers for the Up task (design 11): replacing a running stack, mounting the run layer on the portal, and the
# one line Up ends with. Dot-sourced by .build.ps1 and by tests/Up.Tests.ps1; nothing here calls Docker itself.

# The stamp a compose stack is known by: when its agent container started (UTC, to the second), else when its
# earliest running container did. $null when none of the project's containers is running, i.e. it is not up.
# -Containers is `docker inspect` output for every container of the project, running or not.
function Get-StackStamp {
    param([object[]] $Containers)
    $format = { param($at) ([datetime]::Parse($at, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $running = @($Containers | Where-Object { $_.State.Running })
    if (-not $running) { return $null }
    # A container that never started reports 0001-01-01.
    $started = { param($c) $c.State.StartedAt -and -not $c.State.StartedAt.StartsWith('0001-') }
    $agent = @($Containers | Where-Object { $_.Config.Labels.'com.docker.compose.service' -eq 'agent' -and (& $started $_) }) | Select-Object -First 1
    if ($agent) { return & $format $agent.State.StartedAt }
    $first = @($running | Where-Object { & $started $_ } | Sort-Object { $_.State.StartedAt }) | Select-Object -First 1
    if ($first) { & $format $first.State.StartedAt } else { 'unknown' }
}

# Up's start, the shape of Portal's Invoke-PortalUp: when the stack is up, bring it down, wait for its containers
# to go, then start it; returns { Replaced (the old stamp, or $null); Stamp (the new one) }. With -NoReplace a stack
# that is up throws, and nothing is stopped or started. The name is -Label, never -Project: the scriptblocks run
# in this function's scope, and the build's Invoke-Compose reads $Project from there.
function Invoke-StackUp {
    param(
        [Parameter(Mandatory)] [scriptblock] $GetStamp,
        [Parameter(Mandatory)] [scriptblock] $Down,
        [Parameter(Mandatory)] [scriptblock] $WaitGone,
        [Parameter(Mandatory)] [scriptblock] $Start,
        [string] $Label = 'the compose project',
        [switch] $NoReplace
    )
    $old = & $GetStamp
    if ($old) {
        if ($NoReplace) { throw "$Label is up (since $old); -NoReplace keeps it running. Run Invoke-Build Down, or Up without -NoReplace to replace it." }
        & $Down
        & $WaitGone
    }
    & $Start
    [pscustomobject]@{ Replaced = $old; Stamp = (& $GetStamp) }
}

# True when something accepts a TCP connection on host:port within the timeout.
function Test-PortListening {
    param([string] $HostName = '127.0.0.1', [int] $Port, [int] $TimeoutMilliseconds = 1000)
    $client = [Net.Sockets.TcpClient]::new()
    try { $client.ConnectAsync($HostName, $Port).Wait($TimeoutMilliseconds) -and $client.Connected }
    catch { $false }
    finally { $client.Dispose() }
}

# POST /api/layers on the portal with a path, as Portal's Mount-PortalLayer -Path does: Up passes the layers folder,
# whose newest *.graph.json Portal mounts, reading the ontology.yaml beside it. Returns { Posted; Url; Warning; Response }. A portal that is
# not listening is a warning, never an error; a portal that answers and refuses the layer throws.
function Send-PortalLayer {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Path
    )
    $uri = [uri]$Url
    $base = "$($uri.Scheme)://$($uri.Authority)/"
    if (-not (Test-PortListening -HostName $uri.Host -Port $uri.Port)) {
        return [pscustomobject]@{ Posted = $false; Url = $base; Warning = "portal not up on $($uri.Port)"; Response = $null }
    }
    $body = @{ name = $Name; path = [IO.Path]::GetFullPath($Path) } | ConvertTo-Json -Compress
    $response = Invoke-WebRequest -Uri "${base}api/layers" -Method Post -ContentType 'application/json' -Body $body -SkipHttpErrorCheck -TimeoutSec 30
    if ([int]$response.StatusCode -ge 300) { throw "POST ${base}api/layers ($Name) -> $([int]$response.StatusCode): $($response.Content)" }
    [pscustomobject]@{ Posted = $true; Url = $base; Warning = $null; Response = $(if ($response.Content) { $response.Content | ConvertFrom-Json }) }
}

# The line Up ends with, in the form the other repos' Up tasks print.
function Format-AgentRunLine {
    param([string] $Stamp, [string] $Url, [int] $Nodes, [int] $Edges)
    "agent run $Stamp at $Url ($Nodes nodes, $Edges edges)"
}
