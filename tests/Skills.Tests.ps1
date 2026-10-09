# The two skills copied into this repo must match their sources: run-report from Graph, graph-node from Graph.Node.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $siblings = Split-Path -Parent $repo

    function Get-SkillVersion([string] $Path) {
        $front = [regex]::Match((Get-Content -LiteralPath $Path -Raw), '\A---\r?\n(.*?)\r?\n---', 'Singleline').Groups[1].Value
        [regex]::Match($front, '(?m)^version:\s*(\S+)\s*$').Groups[1].Value
    }

    function Get-SkillFiles([string] $Dir) {
        Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName | ForEach-Object {
            [pscustomobject]@{
                Path = [System.IO.Path]::GetRelativePath($Dir, $_.FullName).Replace('\', '/')
                Text = (Get-Content -LiteralPath $_.FullName -Raw) -replace "`r`n", "`n"
            }
        }
    }
}

Describe 'copied skills' {
    It '<Name> front-matter version equals the version in <Source>' -ForEach @(
        @{ Name = 'run-report'; Source = 'Graph' }
        @{ Name = 'graph-node'; Source = 'Graph.Node' }
    ) {
        $source = Join-Path $siblings "$Source/.claude/skills/$Name/SKILL.md"
        if (-not (Test-Path -LiteralPath $source)) { Set-ItResult -Skipped -Because "$Source is not checked out at $source"; return }
        Get-SkillVersion (Join-Path $repo ".claude/skills/$Name/SKILL.md") | Should -Be (Get-SkillVersion $source) -Because "recopy .claude/skills/$Name from $Source when its version changes"
    }

    It '<Name> is an unchanged copy of <Source>''s, reference files included' -ForEach @(
        @{ Name = 'run-report'; Source = 'Graph' }
        @{ Name = 'graph-node'; Source = 'Graph.Node' }
    ) {
        $source = Join-Path $siblings "$Source/.claude/skills/$Name"
        if (-not (Test-Path -LiteralPath $source)) { Set-ItResult -Skipped -Because "$Source is not checked out at $source"; return }
        $mine = @(Get-SkillFiles (Join-Path $repo ".claude/skills/$Name"))
        $theirs = @(Get-SkillFiles $source)
        @($mine.Path) | Should -Be @($theirs.Path)
        for ($i = 0; $i -lt $mine.Count; $i++) { $mine[$i].Text | Should -Be $theirs[$i].Text -Because "$($mine[$i].Path) is a copy; do not edit it here" }
    }
}
