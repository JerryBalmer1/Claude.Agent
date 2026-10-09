#Requires -Version 7.4
# git-guard: a Claude Code PreToolUse hook for the Bash and PowerShell tools. Reads the hook JSON from stdin and
# denies (exit 2, reason on stderr) a command that commits, pushes, tags, amends, merges a PR or creates a release.
# Anything else, including input that is not hook JSON, exits 0. See SKILL.md for the patterns and their limits.

$deny = @(
    '(?m)(^|[;&|])\s*git\s+(commit|push|tag)\b'
    '(?m)(^|[;&|])\s*git\b[^;&|\r\n]*\s--amend\b'
    '(?m)(^|[;&|])\s*gh\s+pr\s+merge\b'
    '(?m)(^|[;&|])\s*gh\s+release\s+create\b'
)

$raw = [Console]::In.ReadToEnd()
try { $command = [string](ConvertFrom-Json -InputObject $raw -ErrorAction Stop).tool_input.command }
catch { exit 0 }
if (-not $command) { exit 0 }

foreach ($pattern in $deny) {
    if ($command -match $pattern) {
        [Console]::Error.WriteLine('git-guard: agents edit and stage only; commits are run by Jerry from a separate shell')
        exit 2
    }
}
exit 0
