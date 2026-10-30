Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Limits were sized against real github/docs history; exceeding one fails closed
# instead of silently truncating analysis and advancing the checkpoint.
$script:Limits = @{
    ChangedFiles = 5000
    ScannedFiles = 30000
    FileBytes = 4194304
    Candidates = 20
    Occurrences = 5
    ExcerptLines = 2
    EvidenceBytes = 1048576
    HistoryPages = 5
    HistoryPageSize = 100
    HttpRequests = 200
    HttpBytes = 16777216
    GitSeconds = 900
}
$script:HttpRequestCount = 0
$script:HttpByteCount = 0L
$script:WorkflowPath = '.github/workflows/docs-preview-compatibility.lock.yml'
$script:CheckpointArtifact = 'preview-compatibility-checkpoint'
$script:UpstreamUrl = 'https://github.com/github/docs.git'
$script:SparsePatterns = @('/content/**/*.md', '/data/**/*.md', '/data/**/*.yml', '/data/**/*.yaml')
$script:RendererMap = @{
    'liquid-tag' = @('DocsLiquidEvaluator')
    'liquid-filter' = @('DocsLiquidEvaluator')
    'operator' = @('DocsLiquidEvaluator', 'VersionExpressionEvaluator')
    'data-root' = @('DocsLiquidEvaluator', 'DocsLiquidContextLoader')
    'octicon' = @('DocsLiquidEvaluator')
    'octicon-option' = @('DocsLiquidEvaluator')
    'version-ident' = @('VersionExpressionEvaluator')
    'versions-key' = @('VersionExpressionEvaluator', 'DocsLiquidContextLoader')
    'alert' = @('MarkdownPreviewRenderer')
    'fence' = @('MarkdownCodeBlockRenderer', 'MarkdownPreviewRenderer')
    'html' = @('MarkdownPreviewRenderer')
    'layout' = @('MarkdownPreviewRenderer')
    'table-structure' = @('DocsLiquidContextLoader', 'DocsLiquidEvaluator')
    'implementation' = @('DocsLiquidEvaluator', 'MarkdownPreviewRenderer')
}

function Assert-WatcherSha {
    param([string]$Sha)
    if ($Sha -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Expected a full, lowercase, 40-character commit SHA.'
    }
}

function Assert-WatcherPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 512 -or
        $Path -match '[\x00-\x1f\x7f\\:]' -or $Path.StartsWith('/') -or
        @($Path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0) {
        throw 'Invalid upstream repository-relative path.'
    }
}

function Get-WatcherHash {
    param([string]$Text)
    [Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($Text)))
}

function Invoke-WatcherJson {
    param([scriptblock]$Request, [string]$Path, [switch]$AllowMissing)
    $value = & $Request $Path
    if ($null -eq $value -and -not $AllowMissing) {
        throw "Required GitHub resource is unavailable: $Path"
    }
    $value
}

function Invoke-WatcherGitHubRequest {
    param([string]$Path, [string]$Token = $env:GH_TOKEN)
    if (-not $Path.StartsWith('/repos/') -or $Path -match '[\x00-\x20\x7f]') {
        throw 'Invalid GitHub API resource.'
    }
    if (++$script:HttpRequestCount -gt $script:Limits.HttpRequests) { throw 'GitHub request budget exceeded.' }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $uri = [Uri]::new("https://api.github.com$Path")
        if ($uri.Host -cne 'api.github.com') { throw 'Unexpected GitHub API host.' }
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('RepoSyncRadar-preview-compatibility')
        $client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2022-11-28')
        if (-not [string]::IsNullOrEmpty($Token)) {
            $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
        }
        $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        try {
            if ([int]$response.StatusCode -eq 404) { return $null }
            if ([int]$response.StatusCode -eq 302 -and $Path -match '/artifacts/\d+/zip$') {
                $location = $response.Headers.Location
                if ($location.Scheme -cne 'https' -or
                    -not ($location.Host.EndsWith('.blob.core.windows.net') -or $location.Host.EndsWith('.actions.githubusercontent.com'))) {
                    throw 'Unexpected artifact download host.'
                }
                $client.DefaultRequestHeaders.Authorization = $null
                $response.Dispose()
                $response = $client.GetAsync($location, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            }
            if (-not $response.IsSuccessStatusCode) {
                throw "GitHub API request failed with HTTP $([int]$response.StatusCode)."
            }
            $limit = if ($Path -match '/artifacts/\d+/zip$') { 65536 } else { 4194304 }
            if ($response.Content.Headers.ContentLength -gt $limit) { throw 'GitHub response exceeds the byte limit.' }
            $stream = $response.Content.ReadAsStream()
            $buffer = [byte[]]::new(8192)
            $body = [IO.MemoryStream]::new()
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            try {
                do {
                    $remaining = $deadline - [DateTime]::UtcNow
                    if ($remaining -le [TimeSpan]::Zero) { throw 'GitHub response read timed out.' }
                    $cancellation = [Threading.CancellationTokenSource]::new($remaining)
                    try { $count = $stream.ReadAsync($buffer, 0, $buffer.Length, $cancellation.Token).GetAwaiter().GetResult() }
                    finally { $cancellation.Dispose() }
                    if ($body.Length + $count -gt $limit) { throw 'GitHub response exceeds the byte limit.' }
                    $script:HttpByteCount += $count
                    if ($script:HttpByteCount -gt $script:Limits.HttpBytes) { throw 'GitHub response byte budget exceeded.' }
                    $body.Write($buffer, 0, $count)
                } while ($count -gt 0)
                if ($Path -match '/artifacts/\d+/zip$') { return ,$body.ToArray() }
                [Text.UTF8Encoding]::new($false, $true).GetString($body.ToArray()) | ConvertFrom-Json -AsHashtable
            } finally {
                $body.Dispose()
                $stream.Dispose()
            }
        } finally { $response.Dispose() }
    } finally { $client.Dispose() }
}


function Read-WatcherCheckpointArchive {
    param([byte[]]$Bytes)
    if ($Bytes.Length -gt 65536) { throw 'Checkpoint archive is too large.' }
    $stream = [IO.MemoryStream]::new($Bytes, $false)
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read)
    try {
        if ($archive.Entries.Count -ne 1 -or $archive.Entries[0].FullName -ne 'checkpoint.json' -or
            $archive.Entries[0].Length -gt 8192) {
            throw 'Invalid checkpoint archive contents.'
        }
        $reader = [IO.StreamReader]::new($archive.Entries[0].Open())
        try { $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
        finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function Assert-WatcherCheckpoint {
    param(
        [System.Collections.IDictionary]$Checkpoint,
        [System.Collections.IDictionary]$Run,
        [string]$Repository,
        [string]$Branch,
        [long]$WorkflowId
    )
    if ($Checkpoint.schema_version -ne 1 -or $Checkpoint.repository -cne $Repository -or
        $Checkpoint.workflow_path -cne $script:WorkflowPath -or
        $Checkpoint.workflow_id -ne $WorkflowId -or $Checkpoint.run_id -ne $Run.id -or
        $Checkpoint.branch -cne $Branch -or $Checkpoint.source_sha -cne $Run.head_sha -or
        $Checkpoint.mode -notin @('bootstrap', 'incremental', 'reset') -or
        ($Checkpoint.candidate_count -isnot [long] -and $Checkpoint.candidate_count -isnot [int]) -or
        $Checkpoint.candidate_count -lt 0 -or $Checkpoint.candidate_count -gt $script:Limits.Candidates) {
        throw 'Checkpoint provenance or schema is invalid; recover with an explicit baseline reset.'
    }
    Assert-WatcherSha $Checkpoint.upstream_sha
}

function Find-WatcherCheckpoint {
    param(
        [scriptblock]$Request, [string]$Repository, [string]$Branch,
        [long]$WorkflowId, [long]$CurrentRunId
    )
    $sawCollection = $false
    for ($page = 1; $page -le $script:Limits.HistoryPages; $page++) {
        $history = Invoke-WatcherJson $Request "/repos/$Repository/actions/workflows/$WorkflowId/runs?branch=$([Uri]::EscapeDataString($Branch))&per_page=$($script:Limits.HistoryPageSize)&page=$page"
        foreach ($run in $history.workflow_runs) {
            if ($run.id -ge $CurrentRunId -or $run.event -notin @('schedule', 'workflow_dispatch') -or
                $run.head_branch -cne $Branch -or $run.workflow_id -ne $WorkflowId -or
                $run.head_repository.full_name -cne $Repository -or
                $run.path -cne $script:WorkflowPath) { continue }
            $artifacts = Invoke-WatcherJson $Request "/repos/$Repository/actions/runs/$($run.id)/artifacts?per_page=100"
            if ($artifacts.total_count -gt 100) { throw 'Run artifact list exceeds the enumeration limit.' }
            $checkpointArtifacts = @($artifacts.artifacts | Where-Object { $_.name -ceq $script:CheckpointArtifact })
            if ($checkpointArtifacts.Count -gt 1) { throw 'Ambiguous checkpoint artifacts.' }
            if ($run.status -eq 'completed' -and $run.conclusion -eq 'success' -and $checkpointArtifacts.Count -eq 1) {
                if ($checkpointArtifacts[0].expired) { throw 'Checkpoint expired; explicitly reset the baseline.' }
                $bytes = & $Request "/repos/$Repository/actions/artifacts/$($checkpointArtifacts[0].id)/zip"
                $checkpoint = Read-WatcherCheckpointArchive $bytes
                Assert-WatcherCheckpoint $checkpoint $run $Repository $Branch $WorkflowId
                $jobs = Invoke-WatcherJson $Request "/repos/$Repository/actions/runs/$($run.id)/jobs?per_page=100"
                if ($jobs.total_count -gt 100) { throw 'Run job list exceeds the enumeration limit.' }
                $collectionSucceeded = @($jobs.jobs | Where-Object {
                    $_.name -ceq 'Collect upstream evidence' -and $_.conclusion -eq 'success'
                }).Count -eq 1
                $verified = $checkpoint.candidate_count -eq 0 -or @($jobs.jobs | Where-Object {
                    $_.name -ceq 'Verify candidate dispositions and publication' -and $_.conclusion -eq 'success'
                }).Count -eq 1
                if ($collectionSucceeded -and $verified) { return $checkpoint }
                $sawCollection = $true
                continue
            }
            $jobs = Invoke-WatcherJson $Request "/repos/$Repository/actions/runs/$($run.id)/jobs?per_page=100"
            if ($jobs.total_count -gt 100) { throw 'Run job list exceeds the enumeration limit.' }
            if (@($jobs.jobs | Where-Object {
                $_.name -ceq 'Collect upstream evidence' -and $_.conclusion -ne 'skipped'
            }).Count -gt 0) { $sawCollection = $true }
        }
        if ($page * $script:Limits.HistoryPageSize -ge $history.total_count) {
            if ($sawCollection) {
                throw 'Previous collection exists but no successful checkpoint is available; explicitly reset the baseline.'
            }
            return $null
        }
    }
    throw 'Workflow history exceeds the enumeration limit; explicitly recover the baseline.'
}


function Test-WatcherContentPath {
    param([string]$Path)
    $Path -cmatch '^(content/.+\.md|data/.+\.(md|ya?ml))$'
}

function Test-WatcherImplementationPath {
    param([string]$Path)
    $Path -cmatch '^src/content-render/(liquid|unified)/.+\.(ts|tsx|js|mjs)$'
}

function Get-WatcherDataShape {
    param([AllowEmptyString()][string]$Text)
    # Key paths and container kinds affect Liquid loops; scalar prose and the
    # number of rows do not, so the shape is the sorted set of distinct paths.
    $paths = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($line in $Text -split '\r?\n') {
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -match '^(\s*(?:-\s*)?)([^:#]+):(?:\s*(.*))?$') {
            $key = "$($Matches[1])$($Matches[2].Trim())"
            $value = "$($Matches[3])".Trim()
            $kind = if ($value -eq '') { 'container' }
                elseif ($value -match '^[>|][-+0-9]*$') { 'block' }
                elseif ($value -match '^[\[{]') { 'flow' }
                else { 'scalar' }
            [void]$paths.Add("${key}:$kind")
        } elseif ($line -match '^(\s*)-\s*') {
            [void]$paths.Add("$($Matches[1])-:item")
        }
    }
    @($paths) -join "`n"
}

function Get-WatcherTokens {
    <#
    Extracts the rendering vocabulary used by a github/docs source file. Prose,
    variable names, and reference targets are deliberately excluded: only new
    constructs that RepoSyncRadar may never have rendered become candidates.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Text,
        [scriptblock]$IsFeature = { param($Name) $false },
        [Collections.Generic.HashSet[string]]$Vocabulary
    )
    $timeout = [TimeSpan]::FromSeconds(10)
    $occurrences = [Collections.Generic.List[object]]::new()
    $newlines = [Collections.Generic.List[int]]::new()
    if ($null -eq $Vocabulary) {
        for ($i = $Text.IndexOf("`n"); $i -ge 0; $i = $Text.IndexOf("`n", $i + 1)) { $newlines.Add($i) }
    }
    function Add-Token([string]$Token, [int]$Position) {
        if ($null -ne $Vocabulary) { [void]$Vocabulary.Add($Token); return }
        $index = $newlines.BinarySearch($Position)
        if ($index -lt 0) { $index = -bnot $index }
        $occurrences.Add([pscustomobject]@{ Token = $Token; Line = $index + 1 })
    }

    foreach ($m in [regex]::Matches($Text, '\{%-?\s*([A-Za-z_][\w-]*)((?:(?!%\}).)*)%\}', 'Singleline', $timeout)) {
        $tag = $m.Groups[1].Value
        $arguments = $m.Groups[2].Value.TrimEnd('-')
        $unquoted = [regex]::Replace($arguments, '"[^"]*"|''[^'']*''', '""', 'None', $timeout)
        Add-Token "liquid-tag:$tag" $m.Index
        if ($tag -in @('data', 'indented_data_reference')) {
            $root = [regex]::Match($arguments, '^\s*([A-Za-z_][\w-]*)')
            if ($root.Success) { Add-Token "data-root:$($root.Groups[1].Value)" $m.Index }
        } elseif ($tag -eq 'octicon') {
            $name = [regex]::Match($arguments, '^\s*(?:["'']|&quot;|&#34;|&#x22;)([\w-]+)')
            if ($name.Success) { Add-Token "octicon:$($name.Groups[1].Value)" $m.Index }
            foreach ($option in [regex]::Matches($arguments, '([A-Za-z_:][-\w:.]*)\s*=', 'None', $timeout)) {
                Add-Token "octicon-option:$($option.Groups[1].Value)" $m.Index
            }
        }
        if ($tag -in @('if', 'elsif', 'unless', 'ifversion', 'when', 'case')) {
            foreach ($op in [regex]::Matches($unquoted, '==|!=|>=|<=|<|>|\b(?:and|or|not|contains)\b', 'None', $timeout)) {
                Add-Token "operator:$($op.Value)" $m.Index
            }
        }
        if ($tag -eq 'ifversion' -or ($tag -eq 'elsif' -and $unquoted -notmatch '["\.\[]')) {
            foreach ($id in [regex]::Matches($unquoted, '(?<![\w.-])[A-Za-z_][\w-]*', 'None', $timeout)) {
                if ($id.Value -notin @('and', 'or', 'not', 'contains') -and -not (& $IsFeature $id.Value)) {
                    Add-Token "version-ident:$($id.Value)" $m.Index
                }
            }
        }
        foreach ($filter in [regex]::Matches($unquoted, '\|\s*([A-Za-z_]\w*)', 'None', $timeout)) {
            Add-Token "liquid-filter:$($filter.Groups[1].Value)" $m.Index
        }
    }
    foreach ($m in [regex]::Matches($Text, '\{\{-?((?:(?!\}\}).)*)\}\}', 'Singleline', $timeout)) {
        $unquoted = [regex]::Replace($m.Groups[1].Value, '"[^"]*"|''[^'']*''', '""', 'None', $timeout)
        foreach ($filter in [regex]::Matches($unquoted, '\|\s*([A-Za-z_]\w*)', 'None', $timeout)) {
            Add-Token "liquid-filter:$($filter.Groups[1].Value)" $m.Index
        }
    }
    foreach ($m in [regex]::Matches($Text, '(?m)^[ \t]*>[ \t]*\[!([A-Za-z]+)\]', 'None', $timeout)) {
        Add-Token "alert:$($m.Groups[1].Value.ToUpperInvariant())" $m.Index
    }
    foreach ($m in [regex]::Matches($Text, '(?m)^[ \t]*(?:`{3,}|~{3,})[ \t]*([A-Za-z][\w+#.-]*)', 'None', $timeout)) {
        Add-Token "fence:$($m.Groups[1].Value.ToLowerInvariant())" $m.Index
    }
    # Code is rendered literally, so HTML-like text inside fences/spans is not markup.
    $masked = [regex]::Replace(
        $Text, '(?ms)^[ \t]*(`{3,}|~{3,})[^\n]*\n.*?^[ \t]*\1[ \t]*$|`[^`\r\n]+`',
        [Text.RegularExpressions.MatchEvaluator]{ param($match) [regex]::Replace($match.Value, '[^\r\n]', ' ') },
        'None', $timeout)
    # Lowercase-only names avoid prose placeholders such as <YOUR-TOKEN>.
    foreach ($m in [regex]::Matches($masked, '<([a-z][a-z0-9-]*)(?=[\s/>])', 'None', $timeout)) {
        Add-Token "html:$($m.Groups[1].Value)" $m.Index
    }
    if ($Path.EndsWith('.md')) {
        $front = [regex]::Match($Text, '\A---\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\z)', 'Singleline', $timeout)
        if ($front.Success) {
            $offset = $front.Groups[1].Index
            foreach ($key in [regex]::Matches($front.Groups[1].Value, '(?m)^layout:[ \t]*([^\r\n]*)', 'None', $timeout)) {
                if ($key.Groups[1].Value.Trim()) {
                    Add-Token "layout:$($key.Groups[1].Value.Trim().Trim('"', "'"))" ($offset + $key.Index)
                }
            }
            $versions = [regex]::Match($front.Groups[1].Value, '(?m)^versions:[ \t]*\r?\n((?:[ \t]+[^\r\n]*(?:\r?\n|\z))*)', 'None', $timeout)
            if ($versions.Success) {
                foreach ($key in [regex]::Matches($versions.Groups[1].Value, '(?m)^[ \t]+([A-Za-z_][\w-]*)[ \t]*:', 'None', $timeout)) {
                    Add-Token "versions-key:$($key.Groups[1].Value)" ($offset + $versions.Groups[1].Index + $key.Index)
                }
            }
        }
    }
    if ($null -eq $Vocabulary) { $occurrences.ToArray() }
}

function Invoke-WatcherGit {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Arguments,
        [int[]]$SuccessCodes = @(0)
    )
    $info = [Diagnostics.ProcessStartInfo]::new('git')
    # Upstream content is data only: never run hooks, filters, or credential prompts.
    $prefix = @('-C', $Directory, '-c', "core.hooksPath=$(Join-Path $Directory '.no-hooks')",
        '-c', 'core.longpaths=true', '-c', 'core.fsmonitor=false', '-c', 'gc.auto=0',
        '-c', 'core.quotePath=false', '-c', 'filter.lfs.process=', '-c', 'filter.lfs.smudge=',
        '-c', 'filter.lfs.required=false', '-c', 'credential.helper=')
    foreach ($argument in $prefix + $Arguments) { $info.ArgumentList.Add($argument) }
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $info.Environment['GIT_LFS_SKIP_SMUDGE'] = '1'
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($script:Limits.GitSeconds * 1000)) {
            $process.Kill($true)
            throw "Upstream Git operation timed out: git $($Arguments[0])."
        }
        $process.WaitForExit()
        if ($process.ExitCode -notin $SuccessCodes) {
            $detail = ($stderr.Result -split '\r?\n' | Where-Object { $_ } | Select-Object -First 1)
            if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
            throw "Upstream Git operation failed: git $($Arguments[0]) exited $($process.ExitCode). $detail"
        }
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result }
    } finally { $process.Dispose() }
}

function Get-WatcherUpstreamHead {
    param([string]$Url, [string]$Directory)
    $output = (Invoke-WatcherGit $Directory @('ls-remote', '--exit-code', $Url, 'refs/heads/main')).Output
    $sha = ($output -split '\s+')[0]
    Assert-WatcherSha $sha
    $sha
}

function Get-WatcherWorktreeFiles {
    param([string]$Root)
    foreach ($directory in @('content', 'data')) {
        $path = Join-Path $Root $directory
        if (Test-Path -LiteralPath $path) {
            Get-ChildItem -LiteralPath $path -Recurse -File |
                Where-Object { $_.Extension -in @('.md', '.yml', '.yaml') }
        }
    }
}

function Read-WatcherFile {
    param([IO.FileInfo]$File)
    if ($File.Length -gt $script:Limits.FileBytes) {
        throw "Upstream file exceeds $($script:Limits.FileBytes) bytes; review the limit."
    }
    [IO.File]::ReadAllText($File.FullName, [Text.UTF8Encoding]::new($false, $true))
}

function New-WatcherFeatureTest {
    param([string]$Root)
    $features = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $path = Join-Path $Root 'data/features'
    if (Test-Path -LiteralPath $path) {
        foreach ($file in Get-ChildItem -LiteralPath $path -File) { [void]$features.Add($file.BaseName) }
    }
    { param($Name) $features.Contains($Name) }.GetNewClosure()
}

function Invoke-WatcherUpstreamAnalysis {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$HeadSha
    )
    Assert-WatcherSha $BaseSha
    Assert-WatcherSha $HeadSha
    if (Test-Path -LiteralPath $Directory) { throw 'The upstream work directory must not already exist.' }
    [void](New-Item -ItemType Directory -Path $Directory)
    $git = { param([string[]]$Arguments, [int[]]$Codes = @(0)) Invoke-WatcherGit $Directory $Arguments $Codes }
    [void](& $git @('init', '--quiet'))
    [void](& $git @('remote', 'add', 'origin', $Url))
    [void](& $git @('fetch', '--quiet', '--no-tags', '--filter=blob:none', '--depth=1', 'origin', $BaseSha))
    $baseTime = [long](& $git @('show', '-s', '--format=%ct', $BaseSha)).Output.Trim()
    # One day of slack covers merge commits whose committer dates precede main's base.
    $since = [DateTimeOffset]::FromUnixTimeSeconds($baseTime - 86400).UtcDateTime.ToString(
        'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    [void](& $git @('fetch', '--quiet', '--no-tags', '--filter=blob:none', "--shallow-since=$since", 'origin', $HeadSha))
    if ((& $git @('merge-base', '--is-ancestor', $BaseSha, $HeadSha) @(0, 1)).ExitCode -ne 0) {
        throw 'Upstream SHAs are not an ancestor-to-descendant range; recover explicitly.'
    }

    $raw = (& $git @('diff', '--name-status', '-z', '-M', '--no-color', $BaseSha, $HeadSha, '--',
        'content', 'data', 'src/content-render')).Output
    $parts = @($raw.Split([char]0) | Where-Object { $_ -ne '' })
    $changes = [Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $parts.Count) {
        $status = $parts[$i].Substring(0, 1)
        if ($status -in @('R', 'C')) {
            $change = @{ status = $status; previous = $parts[$i + 1]; path = $parts[$i + 2] }
            $i += 3
        } else {
            $change = @{ status = $status; previous = $parts[$i + 1]; path = $parts[$i + 1] }
            $i += 2
        }
        Assert-WatcherPath $change.path
        Assert-WatcherPath $change.previous
        $changes.Add($change)
    }
    if ($changes.Count -gt $script:Limits.ChangedFiles) {
        throw 'Changed upstream file limit exceeded; use smaller replay ranges.'
    }

    $sparse = Join-Path $Directory '.git/info/sparse-checkout'
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sparse))
    [IO.File]::WriteAllLines($sparse, [string[]]$script:SparsePatterns, [Text.UTF8Encoding]::new($false))
    [void](& $git @('config', 'core.sparseCheckout', 'true'))
    [void](& $git @('checkout', '--quiet', '--detach', $BaseSha))
    $vocabulary = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $isFeature = New-WatcherFeatureTest $Directory
    $scanned = 0
    foreach ($file in Get-WatcherWorktreeFiles $Directory) {
        if (++$scanned -gt $script:Limits.ScannedFiles) { throw 'Scanned upstream file limit exceeded.' }
        $relative = [IO.Path]::GetRelativePath($Directory, $file.FullName).Replace('\', '/')
        Get-WatcherTokens -Path $relative -Text (Read-WatcherFile $file) -IsFeature $isFeature -Vocabulary $vocabulary
    }
    $tableShapes = @{}
    foreach ($change in $changes) {
        if ($change.status -in @('M', 'R') -and $change.previous -cmatch '^data/tables/.+\.ya?ml$') {
            $file = Get-Item -LiteralPath (Join-Path $Directory $change.previous)
            $tableShapes[$change.path] = Get-WatcherDataShape (Read-WatcherFile $file)
        }
    }

    [void](& $git @('checkout', '--quiet', '--detach', $HeadSha))
    $isFeature = New-WatcherFeatureTest $Directory
    $found = [ordered]@{}
    function Add-Finding([string]$Token, [string]$Path, [int]$Line, [string[]]$Lines) {
        if (-not $found.Contains($Token)) {
            if ($found.Count -ge $script:Limits.Candidates) {
                throw 'Candidate limit exceeded; use smaller replay ranges or review the limit.'
            }
            $found[$Token] = [Collections.Generic.List[object]]::new()
        }
        if ($found[$Token].Count -ge $script:Limits.Occurrences) { return }
        $excerpt = ''
        if ($null -ne $Lines) {
            $first = [Math]::Max(1, $Line - $script:Limits.ExcerptLines)
            $last = [Math]::Min($Lines.Count, $Line + $script:Limits.ExcerptLines)
            $excerpt = @($Lines[($first - 1)..($last - 1)] | ForEach-Object {
                if ($_.Length -gt 400) { $_.Substring(0, 400) } else { $_ }
            }) -join "`n"
        }
        $found[$Token].Add([ordered]@{
            path = $Path; line = $Line; excerpt = $excerpt
            url = "https://github.com/github/docs/blob/$HeadSha/$Path#L$Line"
        })
    }
    $contentChanges = 0
    foreach ($change in $changes) {
        if (Test-WatcherImplementationPath $change.path -or Test-WatcherImplementationPath $change.previous) {
            if ($change.status -in @('A', 'D', 'R', 'C')) {
                Add-Finding "implementation:$($change.status):$($change.path)" $change.path 1 $null
            }
            continue
        }
        if ($change.status -eq 'D' -or -not (Test-WatcherContentPath $change.path)) { continue }
        $contentChanges++
        $file = Get-Item -LiteralPath (Join-Path $Directory $change.path)
        $text = Read-WatcherFile $file
        $lines = $text -split '\r?\n'
        foreach ($occurrence in Get-WatcherTokens -Path $change.path -Text $text -IsFeature $isFeature) {
            if (-not $vocabulary.Contains($occurrence.Token)) {
                Add-Finding $occurrence.Token $change.path $occurrence.Line $lines
            }
        }
        if ($tableShapes.ContainsKey($change.path)) {
            $shape = Get-WatcherDataShape $text
            if ($shape -cne $tableShapes[$change.path]) {
                Add-Finding "table-structure:$($change.path):$((Get-WatcherHash $shape).Substring(0, 16))" $change.path 1 $lines
            }
        }
    }
    $candidates = foreach ($token in @($found.Keys | Sort-Object -CaseSensitive)) {
        $kind = $token.Substring(0, $token.IndexOf(':'))
        [ordered]@{
            fingerprint = Get-WatcherHash "vocabulary-v1:$token"
            kind = $kind
            token = $token.Substring($kind.Length + 1)
            renderers = $script:RendererMap[$kind]
            tests = @($script:RendererMap[$kind] | ForEach-Object {
                "tests/RepoSyncRadar.Core.Tests/Services/Preview/${_}Tests.cs"
            })
            occurrences = @($found[$token].ToArray())
        }
    }
    @{
        candidates = @($candidates)
        changed_files = $changes.Count
        changed_content_files = $contentChanges
        scanned_files = $scanned
        vocabulary_size = $vocabulary.Count
    }
}

function Invoke-PreviewCompatibilityCollection {
    param(
        [Parameter(Mandatory)][scriptblock]$Request,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][long]$RunId,
        [Parameter(Mandatory)][string]$SourceSha,
        [Parameter(Mandatory)][string]$WorkDirectory,
        [string]$UpstreamUrl = $script:UpstreamUrl,
        [string]$BaseSha = '',
        [string]$HeadSha = '',
        [switch]$ResetBaseline
    )
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $RunId -le 0) {
        throw 'Invalid workflow repository or run ID.'
    }
    Assert-WatcherSha $SourceSha
    $replay = -not [string]::IsNullOrEmpty($BaseSha) -or -not [string]::IsNullOrEmpty($HeadSha)
    if ($replay -and ($ResetBaseline -or [string]::IsNullOrEmpty($BaseSha) -or [string]::IsNullOrEmpty($HeadSha))) {
        throw 'Replay requires both base/head SHAs and cannot reset the baseline.'
    }
    if (Test-Path -LiteralPath $WorkDirectory) { throw 'The work directory must not already exist.' }
    [void](New-Item -ItemType Directory -Path $WorkDirectory)
    $workflow = Invoke-WatcherJson $Request "/repos/$Repository/actions/workflows/docs-preview-compatibility.lock.yml"
    if ($workflow.path -cne $script:WorkflowPath) { throw 'Unexpected workflow identity.' }
    $mode = 'replay'
    if ($replay) {
        Assert-WatcherSha $BaseSha
        Assert-WatcherSha $HeadSha
    } else {
        $HeadSha = Get-WatcherUpstreamHead $UpstreamUrl $WorkDirectory
        $checkpoint = if (-not $ResetBaseline) {
            Find-WatcherCheckpoint $Request $Repository $Branch $workflow.id $RunId
        }
        if ($null -eq $checkpoint) {
            $mode = if ($ResetBaseline) { 'reset' } else { 'bootstrap' }
            $BaseSha = $HeadSha
        } else {
            $mode = 'incremental'
            $BaseSha = $checkpoint.upstream_sha
        }
    }
    $analysis = @{
        candidates = @(); changed_files = 0; changed_content_files = 0; scanned_files = 0; vocabulary_size = 0
    }
    if ($BaseSha -cne $HeadSha) {
        $analysis = Invoke-WatcherUpstreamAnalysis $UpstreamUrl (Join-Path $WorkDirectory 'upstream') $BaseSha $HeadSha
    }
    $evidence = [ordered]@{
        schema_version = 2; upstream_repository = 'github/docs'
        base_sha = $BaseSha; head_sha = $HeadSha; mode = $mode
        changed_files = $analysis.changed_files
        changed_content_files = $analysis.changed_content_files
        scanned_files = $analysis.scanned_files
        vocabulary_size = $analysis.vocabulary_size
        candidates = @($analysis.candidates)
    }
    $json = $evidence | ConvertTo-Json -Depth 30
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:Limits.EvidenceBytes) {
        throw 'Evidence byte limit exceeded; no checkpoint can be advanced.'
    }
    @{
        evidence = $evidence
        checkpoint = if (-not $replay) {
            [ordered]@{
                schema_version = 1; repository = $Repository; workflow_path = $script:WorkflowPath
                workflow_id = $workflow.id; branch = $Branch; run_id = $RunId
                source_sha = $SourceSha; upstream_sha = $HeadSha; mode = $mode
                candidate_count = @($analysis.candidates).Count
            }
        } else { $null }
    }
}

function Assert-PreviewCompatibilityReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Evidence,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Report,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][scriptblock]$Request,
        [string]$CreatedIssueNumber = '',
        [string]$CreatedPullRequestNumber = '',
        [string]$DefaultBranch = 'main'
    )
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Invalid repository.' }
    if ($Evidence.schema_version -ne 2 -or $Report.schema_version -ne 1 -or
        $Report.base_sha -cne $Evidence.base_sha -or $Report.head_sha -cne $Evidence.head_sha -or
        $Report.candidates -isnot [array] -or $Report.candidates.Count -ne $Evidence.candidates.Count) {
        throw 'Report schema or candidate coverage is invalid.'
    }
    $fingerprints = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in $Evidence.candidates) { [void]$fingerprints.Add($candidate.fingerprint) }
    $publications = @{}
    $resolvedCases = [Collections.Generic.List[object]]::new()
    $needsIssue = $false
    $needsPr = $false
    foreach ($case in $Report.candidates) {
        if ($case -isnot [System.Collections.IDictionary] -or -not $fingerprints.Remove($case.fingerprint)) {
            throw 'Report contains a duplicate or unknown candidate fingerprint.'
        }
        foreach ($field in @('status', 'explanation', 'docs_version', 'expected', 'actual', 'reproduction',
            'command', 'before_result', 'after_result', 'issue', 'pull_request')) {
            if ($case[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($case[$field])) {
                throw "Report is missing the required text field: $field"
            }
        }
        if ($case.status -cnotin @('supported', 'intentional-fallback', 'confirmed', 'unresolved')) {
            throw 'Report has an unknown disposition.'
        }
        if (($case.confidence -isnot [int] -and $case.confidence -isnot [long]) -or
            $case.confidence -lt 1 -or $case.confidence -gt 10) {
            throw 'Report confidence must be an integer from 1 to 10.'
        }
        if ($case.status -eq 'unresolved') { throw 'Unresolved candidates prevent checkpoint advancement.' }
        if ($case.status -ne 'confirmed') {
            if ($case.issue -cne 'none' -or $case.pull_request -cne 'none') {
                throw 'Only confirmed cases may request publication.'
            }
            continue
        }
        if ($case.issue -ceq 'none') { throw 'Every confirmed case requires an Issue.' }
        if ($case.pull_request -ceq 'new' -and
            ($case.before_result -cne 'failed' -or $case.after_result -cne 'passed' -or
                -not $case.command.StartsWith('dotnet test tests/RepoSyncRadar.Core.Tests/RepoSyncRadar.Core.Tests.csproj '))) {
            throw 'A proposed PR requires a failing-before/passing-after Core regression command.'
        }
        $issueNumber = 0L
        $prNumber = 0L
        foreach ($kind in @('issue', 'pull_request')) {
            $value = $case[$kind]
            if ($value -ceq 'none') { continue }
            if ($value -ceq 'new') {
                $numberText = if ($kind -eq 'issue') { $CreatedIssueNumber } else { $CreatedPullRequestNumber }
                if ($numberText -cnotmatch '^[1-9][0-9]{0,9}$') {
                    throw "Requested $kind publication was not confirmed by safe outputs."
                }
                $number = [long]$numberText
                if ($kind -eq 'issue') { $needsIssue = $true } else { $needsPr = $true }
            } else {
                $segment = if ($kind -eq 'issue') { 'issues' } else { 'pull' }
                if ($value -cnotmatch "^https://github\.com/$([regex]::Escape($Repository))/$segment/([1-9][0-9]{0,9})$") {
                    throw 'Publication URL is not a canonical link in this repository.'
                }
                $number = [long]$Matches[1]
            }
            $apiKind = if ($kind -eq 'issue') { 'issues' } else { 'pulls' }
            $key = "${apiKind}:$number"
            if (-not $publications.ContainsKey($key)) {
                $publications[$key] = Invoke-WatcherJson $Request "/repos/$Repository/$apiKind/$number"
            }
            $publication = $publications[$key]
            if ($publication.body -isnot [string] -or -not $publication.body.Contains($case.fingerprint)) {
                throw 'Publication does not contain its candidate fingerprint.'
            }
            if ($kind -eq 'issue') {
                if ($publication.Contains('pull_request')) { throw 'An Issue link points to a PR.' }
                $issueNumber = $number
            } elseif ($value -ceq 'new') {
                if (-not $publication.draft -or $publication.base.ref -cne $DefaultBranch -or
                    $publication.body -notmatch "#${issueNumber}\b") {
                    throw 'New PR must be draft, target the default branch, and reference its Issue.'
                }
                $prNumber = $number
            }
        }
        $resolvedCases.Add(@{ issue = $issueNumber; proposed_pr = $prNumber })
    }
    foreach ($case in $resolvedCases) {
        if ($case.proposed_pr -eq 0) { continue }
        $pr = $publications["pulls:$($case.proposed_pr)"]
        $incomplete = @($resolvedCases | Where-Object {
            $_.issue -eq $case.issue -and $_.proposed_pr -ne $case.proposed_pr
        }).Count -gt 0
        if ($incomplete -and $pr.body -match "(?i)\b(?:closes|fixes|resolves)\s+#$($case.issue)\b") {
            throw 'A partial fix must not close an Issue that still has unresolved confirmed cases.'
        }
    }
    if ($fingerprints.Count -ne 0) { throw 'Report omitted evidence fingerprints.' }
    if ((-not $needsIssue -and -not [string]::IsNullOrEmpty($CreatedIssueNumber)) -or
        (-not $needsPr -and -not [string]::IsNullOrEmpty($CreatedPullRequestNumber))) {
        throw 'Safe outputs published an item not declared by the candidate report.'
    }
}


Export-ModuleMember -Function Get-WatcherTokens, Get-WatcherDataShape, Invoke-WatcherUpstreamAnalysis,
    Invoke-PreviewCompatibilityCollection, Assert-WatcherCheckpoint, Read-WatcherCheckpointArchive, Invoke-WatcherGitHubRequest,
    Assert-PreviewCompatibilityReport
