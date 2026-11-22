# build/build-exe.ps1 - bina .exe untuk Windows guna ps2exe
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-exe.ps1
#
# Hasil (dalam .\dist\):
#   VideoStitch.exe   - GUI (tiada konsol)
#   stitch.exe        - CLI
#   bin\stitch.ps1    - enjin yang dipanggil oleh kedua-dua exe
#
# Nota:
# - ps2exe membalut skrip PowerShell; exe MASIH perlukan PowerShell 5.1
#   (ada pada setiap Windows 11) + .NET Framework (ada).
# - ffmpeg kekal sebagai fail luaran (tidak dibundel).
# - Exe yang belum di-sign selalunya kena SmartScreen/AV false positive.

[CmdletBinding()]
param(
    [string] $OutDir,
    [string] $Version = '0.3.2',
    [switch] $SkipInstall,
    [switch] $CliOnly,
    [switch] $GuiOnly
)

$ErrorActionPreference = 'Stop'

if (-not ($env:OS -eq 'Windows_NT')) {
    throw 'build-exe.ps1 hanya untuk Windows (ps2exe guna .NET Framework Windows).'
}

$root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$script:cli = Join-Path $root 'bin\stitch.ps1'
$script:gui = Join-Path $root 'gui\VideoStitchGUI.ps1'
foreach ($f in @($script:cli, $script:gui)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Fail tidak dijumpai: $f" }
}

# 1) ps2exe
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    if ($SkipInstall) { throw 'Modul ps2exe tiada. Jalankan: Install-Module ps2exe -Scope CurrentUser -Force' }
    Write-Host '[1/4] Memasang modul ps2exe (CurrentUser)...' -ForegroundColor Cyan
    if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
        throw 'PowerShellGet tiada. Guna Windows PowerShell 5.1 atau install PowerShellGet.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -Repository PSGallery
}
Import-Module ps2exe -Force
Write-Host ('[1/4] ps2exe {0}' -f (Get-Module ps2exe).Version) -ForegroundColor Green

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'bin') | Out-Null

$common = @{
    title       = 'videoStitch'
    product     = 'videoStitch'
    company     = 'RafieRosliputra'
    description = 'Cantum (stitch) banyak klip video jadi satu'
    version     = $Version
    copyright   = 'MIT License'
}

# 2) CLI exe
if (-not $GuiOnly) {
    Write-Host '[2/4] Bina stitch.exe (CLI)...' -ForegroundColor Cyan
    $p = @{
        InputFile  = $script:cli
        OutputFile = (Join-Path $OutDir 'stitch.exe')
    } + $common
    Invoke-PS2EXE @p
    Write-Host ('      -> {0}' -f (Join-Path $OutDir 'stitch.exe')) -ForegroundColor Green
}

# 3) GUI exe (WinExe, tiada konsol, STA untuk WinForms)
if (-not $CliOnly) {
    Write-Host '[3/4] Bina VideoStitch.exe (GUI)...' -ForegroundColor Cyan
    $p = @{
        InputFile  = $script:gui
        OutputFile = (Join-Path $OutDir 'VideoStitch.exe')
        noConsole  = $true
        STA        = $true
    } + $common
    try {
        Invoke-PS2EXE @p
    }
    catch {
        # versi ps2exe lama tiada -STA; cuba tanpa
        Write-Warning "Gagal dengan -STA ($($_.Exception.Message)); cuba tanpa -STA."
        $p.Remove('STA')
        Invoke-PS2EXE @p
    }
    Write-Host ('      -> {0}' -f (Join-Path $OutDir 'VideoStitch.exe')) -ForegroundColor Green
}

# 4) salin enjin + arahan
Write-Host '[4/4] Salin bin\stitch.ps1 ke dist...' -ForegroundColor Cyan
Copy-Item -LiteralPath $script:cli -Destination (Join-Path $OutDir 'bin\stitch.ps1') -Force
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $OutDir -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Siap. Kandungan dist:' -ForegroundColor Green
Get-ChildItem -LiteralPath $OutDir -Recurse -File | ForEach-Object {
    Write-Host ('  {0,-28} {1,10:N0} B' -f $_.FullName.Substring($OutDir.Length + 1), $_.Length)
}
Write-Host ''
Write-Host 'Guna: double-click VideoStitch.exe  |  stitch.exe -Files "a.mp4,b.mp4" -Out out.mp4'
