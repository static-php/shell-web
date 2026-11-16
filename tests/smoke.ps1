<#
.SYNOPSIS
    Smoke test for public/fetch.ps1, meant to be run on Windows (Windows PowerShell 5.1 and 7+).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke.ps1
#>
[CmdletBinding()]
param(
    [string]$Api = 'https://staticphp.sh'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'public/fetch.ps1'
# fetch.ps1 reports errors through Write-Host, which a caller cannot capture; run the error-path
# checks in a child process so the message and the exit code can both be asserted.
$childExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
$childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
if (-not $childExe) {
    $childExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    $childArgs = @('-NoProfile', '-File', $script)
}
if (-not $childExe) { throw 'neither powershell.exe nor pwsh is available' }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("shell-web-smoke-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$pass = 0
$fail = 0
function Pass([string]$label) { $script:pass++; Write-Host "  ok   $label" }
function Fail-Check([string]$label) { $script:fail++; Write-Host "  FAIL $label" -ForegroundColor Yellow }

try {
    Write-Host "== resolve (metadata path) =="
    $raw = & $script -Version 8.3 -Combination spc-min -Sapi cli -Direct -Json
    if ($LASTEXITCODE -ne 0) { Fail-Check "fetch.ps1 -Direct -Json exited $LASTEXITCODE" }
    else {
        $res = $raw | ConvertFrom-Json
        if ($res.file -like '*-win.zip') { Pass "spc-min resolves to a Windows zip ($($res.file))" } else { Fail-Check "unexpected file '$($res.file)'" }
        if ($res.platform -eq 'win') { Pass 'platform is win' } else { Fail-Check "platform is '$($res.platform)'" }
        if ($res.sha256 -match '^[0-9a-f]{64}$') { Pass 'sha256 present' } else { Fail-Check 'sha256 missing' }
        if ($res.version) { Pass "version $($res.version)" } else { Fail-Check 'version missing' }
    }

    Write-Host "== default combination follows the OS =="
    $dflt = & $script -Version 8.3 -Json
    if ($LASTEXITCODE -eq 0) {
        $dfltRes = $dflt | ConvertFrom-Json
        if ($dfltRes.combination -eq 'spc-max' -and $dfltRes.file -like '*-win.zip') {
            Pass "no -Combination resolves to spc-max on Windows"
        } else {
            Fail-Check "default combination is '$($dfltRes.combination)' ($($dfltRes.file))"
        }
    } else {
        Fail-Check "default resolution exited $LASTEXITCODE"
    }

    Write-Host "== resolve (redirect API) =="
    $apiRaw = & $script -Api $Api -Version 8.3 -Combination spc-min -Sapi micro -Json 2>$null
    if ($LASTEXITCODE -eq 0) {
        $apiRes = $apiRaw | ConvertFrom-Json
        if ($apiRes.file -like '*-win.zip') { Pass "API path resolves ($($apiRes.file))" } else { Fail-Check "API path returned '$($apiRes.file)'" }
    } else {
        Write-Host "  skip  $Api is not serving the API yet"
    }

    Write-Host "== download, verify and extract =="
    & $script -Api $Api -Version 8.3 -Combination spc-min -Sapi cli -Dir $tmp -Extract | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail-Check "download exited $LASTEXITCODE"
    } else {
        $zip = Get-ChildItem $tmp -Filter '*.zip' | Select-Object -First 1
        $exe = Join-Path $tmp 'php.exe'
        if ($zip) { Pass "downloaded $($zip.Name)" } else { Fail-Check 'archive missing' }
        if (Test-Path $exe) {
            Pass 'extracted php.exe'
            $v = & $exe -v 2>&1 | Select-Object -First 1
            if ($v -like 'PHP 8.3.*') { Pass "php.exe runs: $v" } else { Fail-Check "php.exe -v said '$v'" }
        } else {
            Fail-Check 'php.exe was not extracted'
        }
        if ($zip) {
            $expected = ($raw | ConvertFrom-Json).sha256
            $actual = (Get-FileHash -Path $zip.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($actual -eq $expected.ToLowerInvariant()) { Pass 'sha256 matches metadata' } else { Fail-Check 'sha256 mismatch' }
        }
    }

    Write-Host "== rejects cross-platform combinations early =="
    $cases = @(
        @{ Args = @('-Combination', 'bulk'); Match = 'not published for Windows'; Label = 'bulk on windows' },
        @{ Args = @('-Sapi', 'fpm'); Match = 'fpm SAPI is not published'; Label = 'fpm on windows' },
        @{ Args = @('-Combination', 'spc-max', '-Os', 'linux'); Match = 'Windows-only'; Label = 'spc-max on linux' }
    )
    foreach ($case in $cases) {
        $out = & $childExe @childArgs -Version 8.3 @($case.Args) -Json 2>&1
        if ($LASTEXITCODE -ne 0 -and "$out" -match $case.Match) { Pass $case.Label }
        else { Fail-Check "$($case.Label) not rejected ($LASTEXITCODE): $out" }
    }

    Write-Host "== error handling =="
    $out = & $childExe @childArgs -Version 8.3.99 -Combination spc-min -Direct -Json 2>&1
    if ($LASTEXITCODE -ne 0 -and "$out" -match 'newest patch') { Pass 'unknown patch is refused' } else { Fail-Check "unknown patch not refused ($LASTEXITCODE): $out" }
    $out = & $childExe @childArgs -Combination common -Direct -Json 2>&1
    if ($LASTEXITCODE -ne 0 -and "$out" -match 'not published for Windows') { Pass 'wrong platform is refused' } else { Fail-Check "wrong platform not refused ($LASTEXITCODE): $out" }
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "passed: $pass, failed: $fail"
if ($fail -gt 0) { exit 1 }
