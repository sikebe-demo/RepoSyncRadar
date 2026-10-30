[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$FromSha,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ToSha
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# git diff --quiet exits 1 for differences; reset it so pwsh callers do not fail on a valid result.
# Workflow Markdown is executable instruction content, not documentation-only.
git diff --quiet $FromSha $ToSha -- .github/workflows
if ($LASTEXITCODE -eq 1) { $global:LASTEXITCODE = 0; return $true }
if ($LASTEXITCODE -ne 0) { throw 'Unable to compare workflow changes.' }

git diff --quiet $FromSha $ToSha -- . `
    ':(exclude,icase,glob)**/*.md' `
    ':(exclude)apm.yml' `
    ':(exclude)apm.lock.yaml' `
    ':(exclude,glob).agents/skills/**'
if ($LASTEXITCODE -eq 0) { return $false }
if ($LASTEXITCODE -eq 1) { $global:LASTEXITCODE = 0; return $true }
throw 'Unable to compare CI-relevant changes.'
