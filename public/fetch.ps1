<#
.SYNOPSIS
    Download and verify a StaticPHP prebuilt static PHP binary.

.DESCRIPTION
    Resolves the newest published build for a combination/version/platform through
    https://staticphp.sh/fetch.php (or directly from dl.static-php.dev metadata with -Direct),
    downloads the archive, verifies its SHA-256 checksum and optionally unpacks it.

    Works on Windows PowerShell 5.1 and PowerShell 7+ on Windows, Linux and macOS.

.PARAMETER Version
    PHP minor line (8.2, 8.3, 8.4, 8.5), an exact patch such as 8.3.36, or latest. Default: latest.

.PARAMETER Combination
    minimal, common, bulk, gnu-bulk, spc-min or spc-max. Default: common.

.PARAMETER Sapi
    cli, micro or fpm (fpm is not published for Windows). Default: cli.

.PARAMETER Os
    linux, macos or windows. Default: autodetect.

.PARAMETER Arch
    x86_64 or aarch64 (x64, amd64 and arm64 are accepted). Default: autodetect.

.PARAMETER Dir
    Download directory. Default: current directory.

.PARAMETER Extract
    Unpack the binary next to the archive (cli -> php/php.exe, micro -> micro.sfx, fpm -> php-fpm).

.PARAMETER Json
    Print the resolution as JSON instead of downloading.

.PARAMETER Direct
    Skip the redirect API and resolve through the published dl.static-php.dev metadata.

.PARAMETER Api
    Redirect API base. Default: $env:PHP_BIN_API or https://staticphp.sh.

.PARAMETER Base
    Metadata/archive root. Default: $env:PHP_BIN_BASE or https://dl.static-php.dev/v3/php-bin.

.EXAMPLE
    .\fetch.ps1

.EXAMPLE
    .\fetch.ps1 -Version 8.3 -Combination spc-min -Sapi cli -Extract

.EXAMPLE
    .\fetch.ps1 -Version 8.3 -Direct -Json
#>
[CmdletBinding()]
param(
    [string]$Version = 'latest',

    [ValidateSet('minimal', 'common', 'bulk', 'gnu-bulk', 'spc-min', 'spc-max')]
    [string]$Combination = 'common',

    [ValidateSet('cli', 'micro', 'fpm')]
    [string]$Sapi = 'cli',

    [string]$Os = '',

    [string]$Arch = '',

    [string]$Dir = '.',

    [switch]$Extract,

    [switch]$Json,

    [switch]$Direct,

    [string]$Api = $(if ($env:PHP_BIN_API) { $env:PHP_BIN_API } else { 'https://staticphp.sh' }),

    [string]$Base = $(if ($env:PHP_BIN_BASE) { $env:PHP_BIN_BASE } else { 'https://dl.static-php.dev/v3/php-bin' })
)

$ErrorActionPreference = 'Stop'
# Progress rendering on 5.1 dominates the download time for no benefit.
$ProgressPreference = 'SilentlyContinue'

function Stop-WithError {
    param([string]$Message)
    Write-Host "error: $Message" -ForegroundColor Red
    exit 1
}

# ---- platform detection ------------------------------------------------------------
if (-not $Os) {
    if ($PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows) { $Os = 'windows' }
    elseif ($IsMacOS) { $Os = 'macos' }
    elseif ($IsLinux) { $Os = 'linux' }
    else { Stop-WithError 'cannot detect the operating system; pass -Os linux|macos|windows' }
}

if (-not $Arch) {
    $archRaw = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    switch ("$archRaw") {
        'X64' { $Arch = 'x86_64' }
        'Arm64' { $Arch = 'aarch64' }
        default { Stop-WithError "unsupported architecture '$archRaw'; pass -Arch x86_64|aarch64" }
    }
}

$Os = $Os.ToLowerInvariant()
$Arch = switch ($Arch.ToLowerInvariant()) {
    'x64' { 'x86_64' }
    'amd64' { 'x86_64' }
    'arm64' { 'aarch64' }
    default { $_.ToLowerInvariant() }
}

if ($Os -notin @('linux', 'macos', 'windows')) {
    Stop-WithError "os must be linux, macos or windows (got '$Os')"
}
if ($Arch -notin @('x86_64', 'aarch64')) {
    Stop-WithError "arch must be x86_64 or aarch64 (got '$Arch')"
}
if ($Os -eq 'windows' -and $Arch -ne 'x86_64') {
    Stop-WithError 'Windows binaries are only published for x86_64'
}

# Metadata keys platforms as <os>-<arch>, "win" for Windows and <os>-<arch>-gnu for gnu-bulk,
# while the archive file name keeps the plain <os>-<arch> suffix.
if ($Os -eq 'windows') { $Platform = 'win' }
elseif ($Combination -eq 'gnu-bulk') { $Platform = "$Os-$Arch-gnu" }
else { $Platform = "$Os-$Arch" }

function Get-HttpStatusCode {
    param($ErrorRecord)
    try {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    } catch {
        return 0
    }
}

# ---- resolution --------------------------------------------------------------------
function Resolve-ViaApi {
    $query = "combination=$Combination&version=$Version&os=$Os&arch=$Arch&sapi=$Sapi&format=json"
    $uri = "$Api/fetch.php?$query"
    try {
        return Invoke-RestMethod -Uri $uri -TimeoutSec 20
    } catch {
        $status = Get-HttpStatusCode $_
        if ($status -ge 400 -and $status -lt 500) {
            # Only a JSON error from our own endpoint is authoritative: a bare 404 (for example an
            # nginx page while the service is not deployed yet) means "no API here", so fall back.
            $message = $null
            try { $message = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { }
            if ($message) { Stop-WithError "api: $message" }
        }
        return $null
    }
}

function Resolve-ViaMetadata {
    $meta = "$Base/$Combination"
    switch -Regex ($Version) {
        '^latest$' {
            $index = Invoke-RestMethod -Uri "$meta/versions.json" -TimeoutSec 20
            $highest = $null
            foreach ($minor in $index.latest.PSObject.Properties.Name) {
                if (-not $highest -or ([version]($minor + '.0') -gt [version]($highest + '.0'))) { $highest = $minor }
            }
            if (-not $highest) { Stop-WithError "versions.json for '$Combination' has no published minor lines" }
            $ver = $index.latest.$highest
        }
        '^\d+\.\d+$' {
            $index = Invoke-RestMethod -Uri "$meta/versions.json" -TimeoutSec 20
            $ver = $index.latest.$Version
            if (-not $ver) { Stop-WithError "no published version for $Version in combination $Combination" }
        }
        '^\d+\.\d+\.\d+$' { $ver = $Version }
        default { Stop-WithError 'version must be 8.4, an exact patch such as 8.4.27, or latest' }
    }

    $mm = ($ver -split '\.')[0] + ($ver -split '\.')[1]
    $doc = Invoke-RestMethod -Uri "$meta/version_$mm.json" -TimeoutSec 20
    if (($Version -split '\.').Count -eq 3 -and $Version -ne $doc.'php-version') {
        Stop-WithError "only the newest patch is published ($($doc.'php-version')), requested $Version"
    }
    $plat = $doc.artifacts.$Platform
    if (-not $plat) {
        $available = ($doc.artifacts.PSObject.Properties.Name -join ', ')
        Stop-WithError "combination '$Combination' does not publish $Os/$Arch (available: $available)"
    }
    $art = $plat.$Sapi
    if (-not $art -or -not $art.file) {
        Stop-WithError "sapi '$Sapi' is not published for $Combination $Os/$Arch"
    }

    return [pscustomobject]@{
        combination = $Combination
        minor       = ($mm[0] + '.' + $mm[1])
        version     = $doc.'php-version'
        platform    = $Platform
        os          = $Os
        arch        = $Arch
        sapi        = $Sapi
        revision    = $plat.revision
        file        = $art.file
        size        = $art.size
        sha256      = $art.sha256
        url         = "$meta/$($art.file)"
        metadata    = "$meta/version_$mm.json"
    }
}

$resolved = $null
if ($Direct) {
    $resolved = Resolve-ViaMetadata
} else {
    $resolved = Resolve-ViaApi
    if (-not $resolved) {
        Write-Host "note: $Api did not answer, falling back to the published metadata"
        $resolved = Resolve-ViaMetadata
    }
}

if ($Json) {
    $resolved | ConvertTo-Json -Depth 4
    exit 0
}

# ---- download + verify -------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
$target = Join-Path $Dir $resolved.file
Write-Host ("PHP {0} ({1}, {2}/{3}, {4}) -> {5}" -f $resolved.version, $Combination, $Os, $Arch, $Sapi, $target)
Invoke-WebRequest -Uri $resolved.url -OutFile $target -TimeoutSec 600

if ($resolved.sha256) {
    $actual = (Get-FileHash -Path $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $resolved.sha256.ToLowerInvariant()) {
        Stop-WithError "sha256 mismatch for $target (expected $($resolved.sha256), got $actual)"
    }
    Write-Host 'sha256 OK'
} else {
    Write-Host 'warning: no sha256 in the metadata, skipping verification' -ForegroundColor Yellow
}

# ---- optional extraction -----------------------------------------------------------
if ($Extract) {
    if ($resolved.file -like '*.zip') {
        Expand-Archive -Path $target -DestinationPath $Dir -Force
        Write-Host "extracted into $Dir"
    } elseif ($resolved.file -like '*.tar.gz') {
        $member = switch ($Sapi) { 'cli' { 'php' } 'micro' { 'micro.sfx' } 'fpm' { 'php-fpm' } }
        & tar -xzf $target -C $Dir $member
        if ($LASTEXITCODE -ne 0) { Stop-WithError "tar failed to extract $member from $target" }
        Write-Host "extracted $(Join-Path $Dir $member)"
    }
}
