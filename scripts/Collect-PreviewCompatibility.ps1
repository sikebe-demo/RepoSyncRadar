[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PWD 'artifacts\preview-compatibility'),
    [string]$BaseSha = $env:WATCHER_BASE_SHA,
    [string]$HeadSha = $env:WATCHER_HEAD_SHA,
    [switch]$ResetBaseline = ($env:WATCHER_RESET_BASELINE -eq 'true')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PreviewCompatibility.psm1') -Force

if ((Test-Path $OutputPath) -and @(Get-ChildItem -LiteralPath $OutputPath -Force).Count -gt 0) {
    throw 'The output directory must be empty to prevent stale evidence or checkpoint reuse.'
}
[void](New-Item -ItemType Directory -Force -Path $OutputPath)
try {
    $result = Invoke-PreviewCompatibilityCollection -Request { param($Path) Invoke-WatcherGitHubRequest $Path } `
        -Repository $env:GITHUB_REPOSITORY -Branch $env:WATCHER_DEFAULT_BRANCH `
        -RunId ([long]$env:GITHUB_RUN_ID) -SourceSha $env:GITHUB_SHA `
        -WorkDirectory (Join-Path ([IO.Path]::GetTempPath()) "preview-compatibility-$([Guid]::NewGuid().ToString('N'))") `
        -BaseSha $BaseSha -HeadSha $HeadSha -ResetBaseline:$ResetBaseline
    $result.evidence | ConvertTo-Json -Depth 30 |
        Set-Content (Join-Path $OutputPath 'evidence.json') -Encoding utf8NoBOM
    if ($null -ne $result.checkpoint) {
        $checkpointPath = Join-Path $OutputPath 'state'
        [void](New-Item -ItemType Directory -Force -Path $checkpointPath)
        $result.checkpoint | ConvertTo-Json -Depth 10 |
            Set-Content (Join-Path $checkpointPath 'checkpoint.json') -Encoding utf8NoBOM
    }
    if ($env:GITHUB_OUTPUT) {
        @(
            "candidate_count=$($result.evidence.candidates.Count)"
            "checkpoint_eligible=$($null -ne $result.checkpoint)".ToLowerInvariant()
        ) | Add-Content $env:GITHUB_OUTPUT -Encoding utf8
    }
    $summary = "Preview compatibility: mode=$($result.evidence.mode), candidates=$($result.evidence.candidates.Count)."
    Write-Output $summary
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY $summary }
} catch {
    # Do not include upstream text, signed URLs, or HTTP headers in diagnostics.
    @{ schema_version = 1; status = 'failed'; error = $_.Exception.Message } |
        ConvertTo-Json | Set-Content (Join-Path $OutputPath 'failure.json') -Encoding utf8NoBOM
    throw
}
