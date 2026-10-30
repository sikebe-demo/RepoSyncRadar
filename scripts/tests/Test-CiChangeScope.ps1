$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$scopeScript = Join-Path $repoRoot 'scripts\Get-CiChangeScope.ps1'
$fixture = Join-Path $repoRoot "artifacts\watcher-scope-tests\$([Guid]::NewGuid().ToString('N'))"
[void](New-Item -ItemType Directory -Force -Path $fixture)
try {
    git -C $fixture init --quiet
    git -C $fixture config user.name 'Fixture'
    git -C $fixture config user.email 'fixture@example.invalid'
    git -C $fixture config core.hooksPath (Join-Path $fixture 'no-hooks')
    git -C $fixture -c commit.gpgsign=false commit --quiet --allow-empty -m 'Initial fixture'
    Push-Location $fixture
    try {
        $count = 0
        foreach ($case in @(
            @('docs/guide.md', $false),
            @('README.MD', $false),
            @('.github/workflows/watcher.md', $true),
            @('.github/workflows/watcher.lock.yml', $true),
            @('.github/workflows/shared/instructions.md', $true),
            @('.github/aw/actions-lock.json', $true),
            @('tools/gh-aw/go.mod', $true),
            @('scripts/Collect-PreviewCompatibility.ps1', $true),
            @('apm.yml', $false),
            @('apm.lock.yaml', $false),
            @('.agents/skills/example/script.ps1', $false),
            @('src/example.cs', $true)
        )) {
            $from = git rev-parse HEAD
            $path = Join-Path $fixture $case[0]
            [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path))
            Set-Content -LiteralPath $path -Value 'fixture'
            git add --all
            git -c commit.gpgsign=false commit --quiet -m 'Change fixture'
            $to = git rev-parse HEAD
            $actual = & $scopeScript -FromSha $from -ToSha $to
            if ($actual -isnot [bool] -or $actual -ne $case[1]) {
                throw "Incorrect CI scope for $($case[0]): $actual"
            }
            $count++
        }
        Write-Output "Passed $count CI scope git fixtures."
    } finally { Pop-Location }
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
