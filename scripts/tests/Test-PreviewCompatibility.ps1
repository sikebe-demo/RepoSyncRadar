$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\PreviewCompatibility.psm1') -Force

$script:TestCount = 0
$base = 'a' * 40
$head = 'b' * 40
$source = 'c' * 40
$workflowPath = '.github/workflows/docs-preview-compatibility.lock.yml'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:TestCount++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $exception = $null
    try { & $Action | Out-Null } catch { $exception = $_ }
    Assert-True ($null -ne $exception) "Expected failure: $Pattern"
    Assert-True ($exception.Exception.Message -match $Pattern) "Unexpected failure: $($exception.Exception.Message)"
}


function Get-Tokens {
    param([string]$Text, [string]$Path = 'content/example.md', [string[]]$Features = @())
    $isFeature = { param($Name) $Name -in $Features }.GetNewClosure()
    Get-WatcherTokens -Path $Path -Text $Text -IsFeature $isFeature | ForEach-Object Token | Sort-Object -Unique
}

# Prose, reference targets, and variable names are not rendering vocabulary.
Assert-True (@(Get-Tokens 'Plain prose with a [link](/a).').Count -eq 0) 'Prose yields no tokens.'
$data = @(Get-Tokens '{% data variables.product.prodname_vscode %} {% data reusables.copilot.x %}')
Assert-True (($data -join ',') -ceq 'data-root:reusables,data-root:variables,liquid-tag:data') 'Data references keep only roots.'
$swapBefore = Get-Tokens '{% data variables.copilot.copilot_cli_short %}'
$swapAfter = Get-Tokens '{% data variables.product.prodname_vscode_shortname %}'
Assert-True (($swapBefore -join ',') -ceq ($swapAfter -join ',')) 'Variable swaps produce identical vocabulary.'
$cases = @(
    @('{% newtag %}x{% endnewtag %}', 'liquid-tag:newtag'),
    @('{{ page.title | slugify }}', 'liquid-filter:slugify'),
    @('{% if a contains "b" %}x{% endif %}', 'operator:contains'),
    @('{% ifversion ghes > 3.18 %}x{% endif %}', 'operator:>'),
    @('{% ifversion ghes > 3.18 %}x{% endif %}', 'version-ident:ghes'),
    @('{% octicon "home" aria-label="Home" %}', 'octicon:home'),
    @('{% octicon "home" aria-label="Home" %}', 'octicon-option:aria-label'),
    @("> [!caution]`n> Text", 'alert:CAUTION'),
    @("``````mermaid`ngraph TD`n``````", 'fence:mermaid'),
    @('<details><summary>x</summary></details>', 'html:details'),
    @("---`nlayout: product-landing`n---`nBody", 'layout:product-landing'),
    @("---`nversions:`n  fpt: '*'`n  ghes: '*'`n---", 'versions-key:ghes')
)
foreach ($case in $cases) {
    Assert-True ($case[1] -cin (Get-Tokens $case[0])) "Token detected: $($case[1])"
}
Assert-True ('version-ident:copilot-x' -cnotin (Get-Tokens '{% ifversion copilot-x %}a{% endif %}' -Features 'copilot-x')) 'Feature flags are not version identifiers.'
Assert-True (@(Get-Tokens 'Use `<YOUR-TOKEN>` and <TOKEN> placeholders.').Count -eq 0) 'Placeholders are not HTML.'
Assert-True ('html:div' -cnotin (Get-Tokens "``````html`n<div>literal</div>`n``````")) 'Fenced HTML is literal code.'
Assert-True ('operator:>' -cnotin (Get-Tokens '{% if a == "x > y" %}{% endif %}')) 'Quoted text does not create operators.'
Assert-True ('liquid-filter:x' -cnotin (Get-Tokens '{% data "a | x" %}')) 'Quoted pipes are not filters.'
$occurrence = @(Get-WatcherTokens -Path 'content/a.md' -Text "line one`n{% newtag %}" | Where-Object Token -ceq 'liquid-tag:newtag')
Assert-True ($occurrence.Count -eq 1 -and $occurrence[0].Line -eq 2) 'Occurrences report their line.'

$shape = Get-WatcherDataShape "- name: A`n  price: 1`n- name: B`n  price: 2"
Assert-True ($shape -ceq (Get-WatcherDataShape "- name: Z`n  price: 9")) 'Row values and counts are not structure.'
Assert-True ($shape -cne (Get-WatcherDataShape "- name: A`n  cost: 1")) 'Key renames are structure.'
Assert-True ((Get-WatcherDataShape "a:`n  b: 1") -cne (Get-WatcherDataShape "a:`n  - b: 1")) 'Mapping-to-sequence is structure.'

# Upstream fixture: a local Git repository stands in for github/docs.
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "rsr-watcher-$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Path $fixtureRoot)
$upstream = Join-Path $fixtureRoot 'upstream'
[void](New-Item -ItemType Directory -Path $upstream)
function Invoke-FixtureGit { git -C $upstream -c core.hooksPath=NUL -c commit.gpgsign=false @args; if ($LASTEXITCODE -ne 0) { throw "git $args failed." } }
function Set-FixtureFile {
    param([string]$Path, [string]$Text)
    $full = Join-Path $upstream $Path
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full))
    [IO.File]::WriteAllText($full, $Text)
}
function Save-Fixture {
    param([string]$Message)
    Invoke-FixtureGit add -A
    Invoke-FixtureGit -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m $Message
    (git -C $upstream rev-parse HEAD).Trim()
}
Invoke-FixtureGit init --quiet --initial-branch=main
Invoke-FixtureGit config core.autocrlf false
Set-FixtureFile 'content/a.md' "---`nversions:`n  fpt: '*'`n---`n{% data variables.x %} {% octicon `"check`" %}"
Set-FixtureFile 'content/b.md' '{% ifversion fpt %}{% data reusables.a %}{% endif %}'
Set-FixtureFile 'data/features/copilot-x.yml' "versions:`n  fpt: '*'"
Set-FixtureFile 'data/tables/models.yml' "- name: A`n  price: 1"
Set-FixtureFile 'src/content-render/unified/existing.ts' 'export {}'
$fixtureBase = Save-Fixture 'base'
Set-FixtureFile 'content/a.md' "---`nversions:`n  fpt: '*'`n---`n{% data variables.y %} {% octicon `"check`" %} Updated prose."
Set-FixtureFile 'content/new.md' "{% ifversion copilot-x %}New article{% endif %}`n{% data reusables.z %}"
Set-FixtureFile 'data/tables/models.yml' "- name: B`n  price: 2`n- name: C`n  price: 3"
Set-FixtureFile 'src/content-render/unified/existing.ts' 'export const changed = 1'
Set-FixtureFile 'src/frame/components/Hero.tsx' 'export {}'
$fixtureQuiet = Save-Fixture 'routine'
Set-FixtureFile 'content/a.md' "{% octicon `"home`" %}`n``````mermaid`ngraph TD`n``````"
Set-FixtureFile 'data/tables/models.yml' "- name: C`n  cost: 3"
Set-FixtureFile 'src/content-render/unified/mermaid.ts' 'export {}'
Set-FixtureFile 'content/long.md' (('x' * 200) + "`n") * 1000
$fixtureHead = Save-Fixture 'novel'
# [Uri] casts of absolute Unix paths yield an empty AbsoluteUri on Linux, so build the file URL explicitly.
$fixturePath = (Resolve-Path -LiteralPath $upstream).ProviderPath -replace '\\', '/'
if (-not $fixturePath.StartsWith('/')) { $fixturePath = "/$fixturePath" }
$fixtureUrl = "file://$fixturePath"

function New-WorkDirectory { Join-Path $fixtureRoot "work-$([Guid]::NewGuid().ToString('N'))" }
function Invoke-Analysis {
    param([string]$From, [string]$To)
    Invoke-WatcherUpstreamAnalysis -Url $fixtureUrl -Directory (New-WorkDirectory) -BaseSha $From -HeadSha $To
}

$quiet = Invoke-Analysis $fixtureBase $fixtureQuiet
Assert-True ($quiet.candidates.Count -eq 0) 'Routine prose, reference, feature, table-row, implementation-edit, and app-code changes skip inference.'
Assert-True ($quiet.changed_files -eq 4 -and $quiet.changed_content_files -eq 3) 'Unrelated upstream paths are excluded before limits.'

$novel = Invoke-Analysis $fixtureQuiet $fixtureHead
$tokens = @($novel.candidates | ForEach-Object { "$($_.kind):$($_.token)" })
foreach ($expected in @('octicon:home', 'fence:mermaid', 'implementation:A:src/content-render/unified/mermaid.ts')) {
    Assert-True ($expected -cin $tokens) "Novel construct detected: $expected"
}
Assert-True (@($tokens | Where-Object { $_ -like 'table-structure:data/tables/models.yml:*' }).Count -eq 1) 'Table structure change detected.'
Assert-True ($novel.candidates.Count -eq 4) 'Known constructs are not candidates.'
$homeIcon = @($novel.candidates | Where-Object token -ceq 'home')[0]
Assert-True ($homeIcon.fingerprint -cmatch '^[0-9a-f]{64}$' -and $homeIcon.renderers -contains 'DocsLiquidEvaluator') 'Candidates carry fingerprint and renderer mapping.'
Assert-True ($homeIcon.occurrences[0].url -ceq "https://github.com/github/docs/blob/$fixtureHead/content/a.md#L1") 'Occurrences carry pinned permalinks.'
$again = Invoke-Analysis $fixtureQuiet $fixtureHead
Assert-True ((($again.candidates | ForEach-Object fingerprint) -join ',') -ceq (($novel.candidates | ForEach-Object fingerprint) -join ',')) 'Fingerprints are stable across runs.'

Assert-Throws { Invoke-Analysis $fixtureHead $fixtureBase } 'ancestor-to-descendant'
Assert-Throws { Invoke-Analysis $fixtureBase 'Z' } 'commit SHA'
$existing = New-WorkDirectory
[void](New-Item -ItemType Directory -Path $existing)
Assert-Throws { Invoke-WatcherUpstreamAnalysis -Url $fixtureUrl -Directory $existing -BaseSha $fixtureBase -HeadSha $fixtureHead } 'must not already exist'

for ($i = 1; $i -le 21; $i++) { Set-FixtureFile "content/many/$i.md" "{% newtag$i %}" }
$fixtureMany = Save-Fixture 'many'
Assert-Throws { Invoke-Analysis $fixtureHead $fixtureMany } 'Candidate limit'

function New-CheckpointArchive {
    param([hashtable]$Checkpoint, [string]$Name = 'checkpoint.json')
    $stream = [IO.MemoryStream]::new()
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    $entry = $archive.CreateEntry($Name)
    $writer = [IO.StreamWriter]::new($entry.Open())
    $writer.Write(($Checkpoint | ConvertTo-Json -Depth 10))
    $writer.Dispose()
    $archive.Dispose()
    $bytes = $stream.ToArray()
    $stream.Dispose()
    return ,$bytes
}

function New-Run {
    param([long]$Id = 9, [string]$Conclusion = 'success')
    @{
        id = $Id; workflow_id = 42; event = 'schedule'; head_branch = 'main'
        head_repository = @{ full_name = 'owner/repo' }; path = $workflowPath
        head_sha = $source; status = 'completed'; conclusion = $Conclusion
    }
}

function New-Checkpoint {
    @{
        schema_version = 1; repository = 'owner/repo'; workflow_path = $workflowPath
        workflow_id = 42; branch = 'main'; run_id = 9; source_sha = $source
        upstream_sha = $base; mode = 'incremental'; candidate_count = 0
    }
}

$checkpoint = New-Checkpoint
$run = New-Run
Assert-WatcherCheckpoint $checkpoint $run 'owner/repo' 'main' 42
$roundtrip = Read-WatcherCheckpointArchive (New-CheckpointArchive $checkpoint)
Assert-True ($roundtrip.upstream_sha -eq $base) 'Checkpoint archive roundtrip.'
Assert-Throws { Read-WatcherCheckpointArchive (New-CheckpointArchive $checkpoint '../checkpoint.json') } 'archive contents'
$invalid = New-Checkpoint
$invalid.source_sha = 'd' * 40
Assert-Throws { Assert-WatcherCheckpoint $invalid $run 'owner/repo' 'main' 42 } 'provenance'
$invalid = New-Checkpoint
$invalid.schema_version = 99
Assert-Throws { Assert-WatcherCheckpoint $invalid $run 'owner/repo' 'main' 42 } 'provenance'

$script:Responses = @{}
$script:Requests = [Collections.Generic.List[string]]::new()
$request = {
    param($Path)
    $script:Requests.Add($Path)
    if (-not $script:Responses.ContainsKey($Path)) { throw "Unexpected test request: $Path" }
    $value = $script:Responses[$Path]
    if ($value -is [byte[]]) { return ,$value }
    $value
}


$script:Responses = @{}
$script:Requests = [Collections.Generic.List[string]]::new()
$request = {
    param($Path)
    $script:Requests.Add($Path)
    if (-not $script:Responses.ContainsKey($Path)) { throw "Unexpected test request: $Path" }
    $value = $script:Responses[$Path]
    if ($value -is [byte[]]) { return ,$value }
    $value
}

# Upstream main points at the novel commit; checkpoints refer to fixture SHAs.
Invoke-FixtureGit reset --quiet --hard $fixtureHead
$base = $fixtureQuiet
$head = $fixtureHead

function Reset-Responses {
    $script:Requests.Clear()
    $script:Responses.Clear()
    $script:Responses['/repos/owner/repo/actions/workflows/docs-preview-compatibility.lock.yml'] = @{
        id = 42; path = $workflowPath
    }
    $script:Responses['/repos/owner/repo/actions/workflows/42/runs?branch=main&per_page=100&page=1'] = @{
        workflow_runs = @(); total_count = 0
    }
}

function Invoke-Collection {
    param([string]$BaseSha = '', [string]$HeadSha = '', [switch]$ResetBaseline)
    Invoke-PreviewCompatibilityCollection -Request $request -Repository 'owner/repo' `
        -Branch 'main' -RunId 10 -SourceSha $source -WorkDirectory (New-WorkDirectory) -UpstreamUrl $fixtureUrl `
        -BaseSha $BaseSha -HeadSha $HeadSha -ResetBaseline:$ResetBaseline
}

function Add-PreviousCheckpoint {
    param([string]$UpstreamSha = $base)
    $checkpoint = New-Checkpoint
    $checkpoint.upstream_sha = $UpstreamSha
    $script:Responses['/repos/owner/repo/actions/workflows/42/runs?branch=main&per_page=100&page=1'] = @{
        workflow_runs = @((New-Run)); total_count = 1
    }
    $script:Responses['/repos/owner/repo/actions/runs/9/artifacts?per_page=100'] = @{
        artifacts = @(@{ name = 'preview-compatibility-checkpoint'; id = 123; expired = $false }); total_count = 1
    }
    $script:Responses['/repos/owner/repo/actions/artifacts/123/zip'] = New-CheckpointArchive $checkpoint
    $script:Responses['/repos/owner/repo/actions/runs/9/jobs?per_page=100'] = @{
        jobs = @(@{ name = 'Collect upstream evidence'; conclusion = 'success' }); total_count = 1
    }
}

Reset-Responses
$result = Invoke-Collection
Assert-True ($result.evidence.mode -eq 'bootstrap' -and $result.evidence.candidates.Count -eq 0) 'Initial run is baseline-only.'
Assert-True ($result.checkpoint.upstream_sha -eq $head) 'Bootstrap proposes current upstream SHA.'
Assert-True ($result.evidence.schema_version -eq 2 -and $result.evidence.scanned_files -eq 0) 'Bootstrap performs no analysis.'

Reset-Responses
Add-PreviousCheckpoint $head
$result = Invoke-Collection
Assert-True ($result.evidence.mode -eq 'incremental' -and $result.evidence.candidates.Count -eq 0) 'Unchanged upstream succeeds without analysis.'
Assert-True ($result.checkpoint.upstream_sha -eq $head) 'No-candidate runs can advance checkpoint.'

Reset-Responses
Add-PreviousCheckpoint
$result = Invoke-Collection
Assert-True ($result.evidence.base_sha -eq $base -and $result.evidence.candidates.Count -eq 4) 'Incremental run compares from checkpoint.'
Assert-True ($result.checkpoint.candidate_count -eq 4) 'Checkpoint records candidate count for verifier gating.'

Reset-Responses
$result = Invoke-Collection $base $head
Assert-True ($result.evidence.candidates.Count -eq 4 -and $null -eq $result.checkpoint) 'Replay emits evidence but never a checkpoint.'
Assert-True (@($script:Requests | Where-Object { $_ -match '/runs\?' }).Count -eq 0) 'Replay does not read or reset history.'

Reset-Responses
Add-PreviousCheckpoint
$history = $script:Responses['/repos/owner/repo/actions/workflows/42/runs?branch=main&per_page=100&page=1']
$failed = New-Run 8 'failure'
$successful = New-Run 7
$successfulCheckpoint = New-Checkpoint
$successfulCheckpoint.run_id = 7
$successfulCheckpoint.upstream_sha = $base
$history.workflow_runs = @($failed, $successful)
$history.total_count = 2
$script:Responses['/repos/owner/repo/actions/runs/8/artifacts?per_page=100'] = @{
    artifacts = @(@{ name = 'preview-compatibility-checkpoint'; id = 456; expired = $false }); total_count = 1
}
$script:Responses['/repos/owner/repo/actions/runs/8/jobs?per_page=100'] = @{
    jobs = @(@{ name = 'Collect upstream evidence'; conclusion = 'success' }); total_count = 1
}
$script:Responses['/repos/owner/repo/actions/runs/7/artifacts?per_page=100'] = $script:Responses['/repos/owner/repo/actions/runs/9/artifacts?per_page=100']
$script:Responses['/repos/owner/repo/actions/runs/7/jobs?per_page=100'] = $script:Responses['/repos/owner/repo/actions/runs/9/jobs?per_page=100']
$script:Responses['/repos/owner/repo/actions/artifacts/123/zip'] = New-CheckpointArchive $successfulCheckpoint
$result = Invoke-Collection
Assert-True ($result.evidence.base_sha -eq $base -and $result.evidence.candidates.Count -eq 4) 'Failed publication replays from older successful checkpoint.'
Assert-True (-not $script:Requests.Contains('/repos/owner/repo/actions/artifacts/456/zip')) 'Failed-run checkpoint is never trusted.'

Reset-Responses
Add-PreviousCheckpoint
$script:Responses['/repos/owner/repo/actions/runs/9/artifacts?per_page=100'].artifacts[0].expired = $true
Assert-Throws { Invoke-Collection } 'expired'

Reset-Responses
Add-PreviousCheckpoint
$script:Responses['/repos/owner/repo/actions/runs/9/artifacts?per_page=100'] = @{ artifacts = @(); total_count = 0 }
Assert-Throws { Invoke-Collection } 'no successful checkpoint'

Reset-Responses
Add-PreviousCheckpoint
$script:Responses['/repos/owner/repo/actions/runs/9/artifacts?per_page=100'] = @{ artifacts = @(); total_count = 0 }
$script:Responses['/repos/owner/repo/actions/runs/9/jobs?per_page=100'] = @{
    jobs = @(@{ name = 'Collect upstream evidence'; conclusion = 'skipped' }); total_count = 1
}
Assert-True ((Invoke-Collection).evidence.mode -eq 'bootstrap') 'Disabled historical runs do not prevent initial bootstrap.'

Reset-Responses
Add-PreviousCheckpoint
$script:Responses['/repos/owner/repo/actions/workflows/42/runs?branch=main&per_page=100&page=1'].workflow_runs[0].head_repository.full_name = 'attacker/fork'
Assert-True ((Invoke-Collection).evidence.mode -eq 'bootstrap') 'Foreign run is not trusted.'

Reset-Responses
Add-PreviousCheckpoint $fixtureMany
Assert-Throws { Invoke-Collection } 'ancestor-to-descendant'
Assert-Throws { Invoke-Collection $base '' } 'requires both'
Assert-Throws { Invoke-Collection $base $head -ResetBaseline } 'requires both'

Reset-Responses
Assert-True ((Invoke-Collection -ResetBaseline).evidence.mode -eq 'reset') 'Explicit reset only records current head.'

Reset-Responses
Add-PreviousCheckpoint
$unverified = New-Checkpoint
$unverified.upstream_sha = $base
$unverified.candidate_count = 1
$script:Responses['/repos/owner/repo/actions/artifacts/123/zip'] = New-CheckpointArchive $unverified
$script:Responses['/repos/owner/repo/actions/runs/9/jobs?per_page=100'].jobs += @{
    name = 'Verify candidate dispositions and publication'; conclusion = 'skipped'
}
Assert-Throws { Invoke-Collection } 'no successful checkpoint'

Reset-Responses
Add-PreviousCheckpoint
$verified = New-Checkpoint
$verified.upstream_sha = $base
$verified.candidate_count = 1
$script:Responses['/repos/owner/repo/actions/artifacts/123/zip'] = New-CheckpointArchive $verified
$script:Responses['/repos/owner/repo/actions/runs/9/jobs?per_page=100'].jobs += @{
    name = 'Verify candidate dispositions and publication'; conclusion = 'success'
}
Assert-True ((Invoke-Collection).evidence.base_sha -eq $base) 'Candidate checkpoint requires successful publication verifier.'

$candidate1 = $novel.candidates[0]

$evidence = @{ schema_version = 2; base_sha = $base; head_sha = $head; candidates = @($candidate1) }
function New-Report {
    @{
        schema_version = 1; base_sha = $base; head_sha = $head
        candidates = @(@{
            fingerprint = $candidate1.fingerprint; status = 'supported'
            explanation = 'Existing evaluator covers this.'; docs_version = 'fpt'; confidence = 8
            expected = 'Expected rendering'; actual = 'Observed rendering'; reproduction = 'Minimal input'
            command = 'not-run: source inspection establishes existing support'
            before_result = 'not-run'; after_result = 'not-run'; issue = 'none'; pull_request = 'none'
        })
    }
}
function Assert-Report {
    param([hashtable]$Report, [string]$Issue = '', [string]$Pr = '')
    Assert-PreviewCompatibilityReport -Evidence $evidence -Report $Report -Repository 'owner/repo' `
        -Request $request -CreatedIssueNumber $Issue -CreatedPullRequestNumber $Pr
}

$report = New-Report
Assert-Report $report
Assert-True $true 'Complete supported report accepted without publication.'
$report.candidates = @()
Assert-Throws { Assert-Report $report } 'coverage'
$report = New-Report
$report.candidates[0].fingerprint = 'e' * 64
Assert-Throws { Assert-Report $report } 'unknown candidate'
$report = New-Report
$report.candidates[0].status = 'unresolved'
Assert-Throws { Assert-Report $report } 'Unresolved'
$report = New-Report
$report.candidates[0].status = 'confirmed'
Assert-Throws { Assert-Report $report } 'requires an Issue'
$report = New-Report
$report.candidates[0].issue = 'new'
Assert-Throws { Assert-Report $report } 'Only confirmed'
$report = New-Report
$report.candidates[0].status = 'confirmed'
$report.candidates[0].issue = 'new'
Assert-Throws { Assert-Report $report } 'not confirmed'
$report.candidates[0].issue = 'https://github.com/attacker/repo/issues/1'
Assert-Throws { Assert-Report $report } 'canonical link'

$script:Responses['/repos/owner/repo/issues/1'] = @{ body = $candidate1.fingerprint }
$script:Responses['/repos/owner/repo/pulls/2'] = @{
    body = "$($candidate1.fingerprint)`nCloses #1"; draft = $true; base = @{ ref = 'main' }
}
$report.candidates[0].issue = 'https://github.com/owner/repo/issues/1'
Assert-Report $report
Assert-True $true 'Existing fingerprint-matched Issue reused after partial publication failure.'
$report.candidates[0].pull_request = 'new'
Assert-Throws { Assert-Report $report '' '2' } 'failing-before'
$report.candidates[0].before_result = 'failed'
$report.candidates[0].after_result = 'passed'
$report.candidates[0].command = 'dotnet test tests/RepoSyncRadar.Core.Tests/RepoSyncRadar.Core.Tests.csproj -- --filter-class Example'
Assert-Report $report '' '2'
Assert-True $true 'Verified draft PR publication accepted.'
$script:Responses['/repos/owner/repo/pulls/2'].draft = $false
Assert-Throws { Assert-Report $report '' '2' } 'must be draft'
$script:Responses['/repos/owner/repo/pulls/2'].draft = $true
$script:Responses['/repos/owner/repo/issues/1'].body = 'Unrelated'
Assert-Throws { Assert-Report $report '' '2' } 'fingerprint'
$script:Responses['/repos/owner/repo/issues/1'].body = $candidate1.fingerprint
$report.candidates[0].issue = 'new'
Assert-Report $report '1' '2'
Assert-True $true 'Issue and linked draft PR confirmed through safe-output numbers.'
$report = New-Report
Assert-Throws { Assert-Report $report '1' '' } 'not declared'

foreach ($invalidConfidence in @(0, 11, '8', 8.5)) {
    $report = New-Report
    $report.candidates[0].confidence = $invalidConfidence
    Assert-Throws { Assert-Report $report } 'confidence'
}
$report = New-Report
$report.candidates[0].Remove('expected')
Assert-Throws { Assert-Report $report } 'required text field'
$report = New-Report
$report.head_sha = $base
Assert-Throws { Assert-Report $report } 'coverage'

# Both confirmed cases share an aggregated Issue; only the first has a fix.
$evidence.candidates += $novel.candidates[1]
$report = New-Report
$report.candidates[0].status = 'confirmed'
$report.candidates[0].issue = 'new'
$report.candidates[0].pull_request = 'new'
$report.candidates[0].before_result = 'failed'
$report.candidates[0].after_result = 'passed'
$report.candidates[0].command = 'dotnet test tests/RepoSyncRadar.Core.Tests/RepoSyncRadar.Core.Tests.csproj -- --filter-class Example'
$secondCase = (New-Report).candidates[0]
$secondCase.fingerprint = $evidence.candidates[1].fingerprint
$secondCase.status = 'confirmed'
$secondCase.issue = 'new'
$report.candidates += $secondCase
$allFingerprints = ($evidence.candidates | ForEach-Object { $_.fingerprint }) -join "`n"
$script:Responses['/repos/owner/repo/issues/1'].body = $allFingerprints
$script:Responses['/repos/owner/repo/pulls/2'].body = "$($candidate1.fingerprint)`nCloses #1"
Assert-Throws { Assert-Report $report '1' '2' } 'partial fix'
$script:Responses['/repos/owner/repo/pulls/2'].body = "$($candidate1.fingerprint)`nRefs #1"
Assert-Report $report '1' '2'
Assert-True $true 'Partial fix references without closing the aggregated Issue.'

Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
Write-Output "Passed $script:TestCount preview compatibility assertions."
