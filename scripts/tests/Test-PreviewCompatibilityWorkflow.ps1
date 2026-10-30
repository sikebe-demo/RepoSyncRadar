$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$workflow = Get-Content (Join-Path $repoRoot '.github\workflows\docs-preview-compatibility.md') -Raw
$lock = Get-Content (Join-Path $repoRoot '.github\workflows\docs-preview-compatibility.lock.yml') -Raw
$compilerPin = Get-Content (Join-Path $repoRoot 'tools\gh-aw\go.mod') -Raw
$script:Count = 0

function Assert-Policy {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Workflow policy violation: $Message" }
    $script:Count++
}

$manifestLine = [regex]::Match($lock, '(?m)^# gh-aw-manifest: (.+)$')
Assert-Policy $manifestLine.Success 'Compiled dependency manifest is required.'
$manifest = $manifestLine.Groups[1].Value | ConvertFrom-Json -AsHashtable
$compilerVersion = [regex]::Match($compilerPin, '(?m)^require github\.com/github/gh-aw (v\d+\.\d+\.\d+)\s*$')
Assert-Policy $compilerVersion.Success 'Compiler version must be Dependabot-managed and exact.'
$metadataLine = [regex]::Match($lock, '(?m)^# gh-aw-metadata: (.+)$')
Assert-Policy $metadataLine.Success 'Compiled metadata is required.'
$metadata = $metadataLine.Groups[1].Value | ConvertFrom-Json -AsHashtable
Assert-Policy ($metadata.compiler_version -ceq $compilerVersion.Groups[1].Value) 'Generated workflow must use the pinned compiler.'
foreach ($action in $manifest.actions) {
    Assert-Policy ($action.sha -cmatch '^[0-9a-f]{40}$') 'All generated external actions must be SHA-pinned.'
}
$jobs = @{}
$jobSection = ($lock -split '(?m)^jobs:\r?$', 2)[1]
foreach ($match in [regex]::Matches($jobSection, '(?ms)^  ([a-z_]+):\r?\n(.*?)(?=^  [a-z_]+:\r?\n|\z)')) {
    $jobs[$match.Groups[1].Value] = $match.Groups[2].Value
}
foreach ($job in @('activation', 'collect', 'agent', 'detection', 'safe_outputs', 'verify', 'conclusion')) {
    Assert-Policy ($jobs.ContainsKey($job)) "Required job: $job"
}
Assert-Policy ($jobs.Count -eq 7) 'New compiler jobs require explicit policy review.'
foreach ($job in @('collect', 'agent', 'detection', 'safe_outputs', 'verify')) {
    Assert-Policy ($jobs[$job] -match '(?m)^    timeout-minutes: [1-9][0-9]?\r?$') "Bounded timeout required for $job."
}
Assert-Policy ($jobs.activation.Contains("vars.PREVIEW_COMPATIBILITY_ENABLED == 'true'")) 'Activation is disabled when the variable is unset.'
Assert-Policy ($jobs.activation.Contains("github.event.repository.default_branch")) 'Activation is default-branch-only.'
Assert-Policy ($jobs.collect -match '(?m)^    needs: activation$') 'Collection waits for activation.'
Assert-Policy ($jobs.agent.Contains("needs.collect.outputs.candidate_count != '0'")) 'Zero candidates must skip the agent.'
Assert-Policy ($jobs.detection.Contains("needs.agent.result != 'skipped'")) 'Zero-candidate runs must skip inference-based detection.'
Assert-Policy ($jobs.verify.Contains("needs.detection.outputs.detection_success == 'true'")) 'Untrusted reports require successful detection.'
Assert-Policy ($jobs.verify.Contains('- safe_outputs')) 'Publication verification must wait for safe outputs.'
Assert-Policy ($jobs.verify.Contains('ref: ${{ github.sha }}')) 'Validation uses trusted source, not the agent branch.'
Assert-Policy ($jobs.safe_outputs.Contains('GH_AW_CI_TRIGGER_TOKEN: ${{ secrets.GH_AW_CI_TRIGGER_TOKEN }}')) 'CI trigger token is confined to publication.'
Assert-Policy (-not $jobs.agent.Contains('secrets.GH_AW_CI_TRIGGER_TOKEN')) 'Agent must not receive the CI write credential.'
Assert-Policy (-not $jobs.detection.Contains('secrets.GH_AW_CI_TRIGGER_TOKEN')) 'Detection must not receive the CI write credential.'
Assert-Policy ($jobs.agent -notmatch '(?m)^      (contents|issues|pull-requests): write$') 'Agent has read-only GitHub permissions.'
Assert-Policy ($manifest.threat_detection.mode -eq 'enabled') 'Built-in threat detection remains enabled.'

$configLine = [regex]::Match($jobs.safe_outputs, '(?m)^\s+GH_AW_SAFE_OUTPUTS_HANDLER_CONFIG: (".*")\r?$')
Assert-Policy $configLine.Success 'Generated safe-output policy is required.'
$config = ($configLine.Groups[1].Value | ConvertFrom-Json) | ConvertFrom-Json -AsHashtable
Assert-Policy ($config.create_issue.max -eq 1 -and $config.create_issue.deduplicate_by_title) 'Issue publication is bounded and deduplicated.'
Assert-Policy ($config.create_pull_request.max -eq 1 -and $config.create_pull_request.draft) 'Only one draft PR is permitted.'
Assert-Policy (-not $config.create_pull_request.fallback_as_issue -and -not $config.create_pull_request.stacked) 'No extra fallback Issues or stacked PRs.'
Assert-Policy ($config.create_pull_request.protected_files_policy -ceq 'blocked') 'Protected files must be blocked.'
Assert-Policy ($config.create_pull_request.max_patch_files -eq 8 -and $config.create_pull_request.max_patch_size -eq 128) 'Patch size limits remain bounded.'
$expectedPaths = @(
    'src/RepoSyncRadar.Core/Services/Preview/*.cs',
    'tests/RepoSyncRadar.Core.Tests/Services/Preview/*.cs'
)
Assert-Policy (($config.create_pull_request.allowed_files -join "`n") -ceq ($expectedPaths -join "`n")) 'Only preview implementation and test paths may be published.'
$expectedHandlers = @('create_issue', 'create_pull_request', 'noop', 'report_incomplete', 'report_missing_data', 'report_missing_tool')
Assert-Policy ((($config.Keys | Sort-Object) -join ',') -ceq (($expectedHandlers | Sort-Object) -join ',')) 'No approval/merge/release/dispatch/update handlers.'
Assert-Policy ($workflow.Contains('report-failure-as-issue: false') -and $workflow.Contains('report-failed-jobs: false')) 'Failure paths must not publish extra Issues.'
Assert-Policy ($workflow.Contains('report-as-issue: false')) 'No-op runs do not post notification comments.'
Assert-Policy ($workflow.Contains('cancel-in-progress: false')) 'In-flight publication must not be cancelled by the next run.'
Assert-Policy ($jobs.collect.Contains('name: preview-compatibility-checkpoint') -and
    -not $jobs.agent.Contains('name: preview-compatibility-checkpoint')) 'Only deterministic collection may propose a checkpoint.'
foreach ($job in @('collect', 'verify')) {
    Assert-Policy ($jobs[$job].Contains('persist-credentials: false')) "Trusted $job checkout must not persist credentials."
}
Write-Output "Passed $script:Count compiled workflow policy assertions."
