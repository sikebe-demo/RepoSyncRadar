[CmdletBinding()]
param([string]$GhalintPath = 'ghalint')

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$executable = (Get-Command $GhalintPath -CommandType Application -ErrorAction Stop |
    Select-Object -First 1).Source
$staging = Join-Path $repoRoot "artifacts\workflow-lint\$([Guid]::NewGuid().ToString('N'))"
$stagedGithub = Join-Path $staging '.github'
[void](New-Item -ItemType Directory -Force -Path (Join-Path $stagedGithub 'workflows'))
try {
    # Only this compiler-owned output uses regeneration and dedicated policy checks
    # instead of ghalint; every authored YAML and local action remains linted.
    $generated = Join-Path $repoRoot '.github\workflows\docs-preview-compatibility.lock.yml'
    foreach ($file in Get-ChildItem (Join-Path $repoRoot '.github\workflows') -Recurse -File) {
        if ($file.Extension -notin @('.yml', '.yaml') -or $file.FullName -eq $generated) { continue }
        $relative = [IO.Path]::GetRelativePath($repoRoot, $file.FullName)
        $destination = Join-Path $staging $relative
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination))
        Copy-Item -LiteralPath $file.FullName -Destination $destination
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot '.github\ghalint.yaml') -Destination $stagedGithub
    $actions = Join-Path $repoRoot '.github\actions'
    if (Test-Path -LiteralPath $actions) { Copy-Item -LiteralPath $actions -Destination $stagedGithub -Recurse }
    Push-Location $staging
    try {
        & $executable run
        if ($LASTEXITCODE -ne 0) { throw 'Authored workflow lint failed.' }
    } finally { Pop-Location }
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
