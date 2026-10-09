# git-guard, run-report and graph-node are copied read-only from Graph (C:\__Code\Graph): each must equal Graph's
# committed (HEAD) copy, reference files included. Recopy the whole folder when its version: changes; never edit it here.

BeforeDiscovery {
    $script:Skills = @(
        @{ Skill = 'git-guard' }
        @{ Skill = 'run-report' }
        @{ Skill = 'graph-node' }
    )
    $script:Commands = @(
        @{ Command = 'git status'; Code = 0 }
        @{ Command = 'git add -A'; Code = 0 }
        @{ Command = 'git commit -m x'; Code = 2 }
        @{ Command = 'git push'; Code = 2 }
        @{ Command = 'git tag v1'; Code = 2 }
        @{ Command = 'gh pr merge 1'; Code = 2 }
    )
}

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Source = 'C:\__Code\Graph'
    $script:HasSource = Test-Path -LiteralPath (Join-Path $Source '.git')
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

    # git's stdout from the Graph checkout as lines joined with LF; $null when git fails.
    function Get-Committed([string[]] $GitArgs) {
        $out = & git -C $Source @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        $out -join "`n"
    }

    function Get-FrontVersion([string] $Text) {
        $front = [regex]::Match($Text, '\A---\r?\n(.*?)\r?\n---', 'Singleline').Groups[1].Value
        [regex]::Match($front, '(?m)^version:\s*(\S+)\s*$').Groups[1].Value
    }

    # Pipes a Bash tool call's hook JSON into hook.ps1 in a fresh process; returns its exit code and stderr.
    function Invoke-Hook([string] $Command) {
        $hook = Join-Path $Repo '.claude/skills/git-guard/hook.ps1'
        $raw = ConvertTo-Json -Compress -InputObject @{ tool_name = 'Bash'; tool_input = @{ command = $Command } }
        $err = Join-Path $TestDrive 'hook.err'
        $raw | & pwsh -NoProfile -File $hook 2> $err | Out-Null
        [pscustomobject]@{ Code = $LASTEXITCODE; Error = (Get-Content -LiteralPath $err -Raw) }
    }
}

Describe 'copied skills (from Graph HEAD)' {
    It '<Skill> front-matter version equals Graph''s committed copy' -ForEach $Skills {
        if (-not $HasSource) { Set-ItResult -Skipped -Because "Graph is not checked out at $Source"; return }
        $committed = Get-Committed 'show', "HEAD:.claude/skills/$Skill/SKILL.md"
        $mine = Get-FrontVersion (Get-Content -LiteralPath (Join-Path $Repo ".claude/skills/$Skill/SKILL.md") -Raw)
        $mine | Should -Match '^\d+\.\d+\.\d+$'
        $mine | Should -Be (Get-FrontVersion $committed) -Because "recopy .claude/skills/$Skill from $Source"
    }

    It '<Skill> is the full text of Graph''s committed copy, every file, line endings aside' -ForEach $Skills {
        if (-not $HasSource) { Set-ItResult -Skipped -Because "Graph is not checked out at $Source"; return }
        $theirs = @((Get-Committed 'ls-tree', '-r', '--name-only', 'HEAD', ".claude/skills/$Skill") -split "`n" | Sort-Object)
        $dir = Join-Path $Repo ".claude/skills/$Skill"
        $mine = @(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object {
                ".claude/skills/$Skill/" + [System.IO.Path]::GetRelativePath($dir, $_.FullName).Replace('\', '/')
            } | Sort-Object)
        $mine | Should -Be $theirs
        foreach ($path in $theirs) {
            (Get-Content -LiteralPath (Join-Path $Repo $path)) -join "`n" | Should -BeExactly (Get-Committed 'show', "HEAD:$path") -Because "$path is a copy; do not edit it here"
        }
    }
}

Describe 'git-guard hook' {
    It 'exits <Code> for <Command>' -ForEach $Commands {
        $r = Invoke-Hook -Command $Command
        $r.Code | Should -Be $Code -Because $r.Error
        if ($Code -eq 2) { $r.Error.Trim() | Should -Be 'git-guard: agents edit and stage only; commits are run by Jerry from a separate shell' }
    }

    It '.claude/settings.json has the fragment''s PreToolUse entry' {
        $fragment = Get-Content -LiteralPath (Join-Path $Repo '.claude/skills/git-guard/settings.fragment.json') -Raw | ConvertFrom-Json
        $settings = Get-Content -LiteralPath (Join-Path $Repo '.claude/settings.json') -Raw | ConvertFrom-Json
        $want = @($fragment.hooks.PreToolUse)
        $want.Count | Should -Be 1
        $have = @($settings.hooks.PreToolUse | ForEach-Object { ConvertTo-Json -Depth 6 -Compress $_ })
        $have | Should -Contain (ConvertTo-Json -Depth 6 -Compress $want[0])
    }
}
