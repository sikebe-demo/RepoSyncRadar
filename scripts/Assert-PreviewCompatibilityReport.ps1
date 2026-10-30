[CmdletBinding()]
param(
    [string]$EvidencePath = (Join-Path $PWD 'artifacts\original-evidence\evidence.json'),
    [string]$ReportPath = (Join-Path $PWD 'artifacts\agent-report\report.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PreviewCompatibility.psm1') -Force
foreach ($path in @($EvidencePath, $ReportPath)) {
    if ((Get-Item -LiteralPath $path).Length -gt 1048576) { throw 'Report or evidence exceeds the byte limit.' }
}
$evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json -AsHashtable
$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json -AsHashtable
Assert-PreviewCompatibilityReport -Evidence $evidence -Report $report -Repository $env:GITHUB_REPOSITORY `
    -Request { param($Path) Invoke-WatcherGitHubRequest $Path } `
    -CreatedIssueNumber $env:CREATED_ISSUE_NUMBER -CreatedPullRequestNumber $env:CREATED_PR_NUMBER `
    -DefaultBranch $env:WATCHER_DEFAULT_BRANCH
$summary = "Verified $($report.candidates.Count) candidate dispositions and their requested publications."
Write-Output $summary
if ($env:GITHUB_STEP_SUMMARY) { Add-Content $env:GITHUB_STEP_SUMMARY $summary }
