<#
.SYNOPSIS
    Pemasang videoStitch - satu klik, tiada admin.

.DESCRIPTION
    Memasang ke %LOCALAPPDATA%\Programs\videoStitch (per-user, tiada UAC):
      1. salin enjin (bin\stitch.ps1) + GUI (gui\VideoStitchGUI.ps1)
      2. cuba compile VideoStitch.exe + stitch.exe guna ps2exe
         (kalau gagal -> VideoStitch.cmd fallback, app tetap boleh guna)
      3. semak ffmpeg; tawarkan pemasangan winget kalau tiada
      4. buat shortcut Desktop + Start Menu
      5. daftar dalam Settings > Apps (HKCU Uninstall) + uninstall.cmd

.PARAMETER Target
    Folder pemasangan. Default: %LOCALAPPDATA%\Programs\videoStitch

.PARAMETER NoCompile
    Jangan compile exe; terus guna VideoStitch.cmd.

.PARAMETER NoFFmpeg
    Jangan tawarkan pemasangan ffmpeg.

.PARAMETER NoShortcuts
    Jangan buat shortcut Desktop/Start Menu.

.PARAMETER DryRun
    Cetak rancangan tanpa ubah apa-apa (untuk ujian pembangun).
#>
[CmdletBinding()]
param(
    [string] $Target,
    [switch] $NoCompile,
    [switch] $NoFFmpeg,
    [switch] $NoShortcuts,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
$isWin = ($env:OS -eq 'Windows_NT')
$Version = '0.1.9'

if (-not $isWin -and -not $DryRun) { throw 'Pemasang ini untuk Windows sahaja.' }

$src = Split-Path -Parent $PSScriptRoot
if (-not $Target) {
    if ($isWin) { $Target = Join-Path $env:LOCALAPPDATA 'Programs\videoStitch' }
    else { $Target = Join-Path ([IO.Path]::GetTempPath()) 'videoStitch-dryrun' }
}

function Say  { param([string] $m, [string] $c = 'Gray') Write-Host $m -ForegroundColor $c }
function Step { param([int] $n, [string] $m) Write-Host "[$n/6] $m" -ForegroundColor Cyan }

# --------------------------------------------------------------- payload ----

function Copy-Payload {
    $map = @(
        @{ From = 'bin/stitch.ps1';         To = 'bin/stitch.ps1' },
        @{ From = 'gui/VideoStitchGUI.ps1'; To = 'gui/VideoStitchGUI.ps1' },
        @{ From = 'install/uninstall.ps1';  To = 'uninstall.ps1' },
        @{ From = 'README.md';              To = 'README.md' },
        @{ From = 'LICENSE';                To = 'LICENSE' }
    )
    foreach ($m in $map) {
        $from = Join-Path $src $m.From
        if (-not (Test-Path -LiteralPath $from)) { throw "Payload tiada: $from" }
        $to = Join-Path $Target $m.To
        $dir = Split-Path -Parent $to
        if (-not (Test-Path -LiteralPath $dir)) {
            if ($DryRun) { Say "       (dry) mkdir $dir" } else { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        }
        if ($DryRun) { Say "       (dry) copy $($m.From) -> $($m.To)" }
        else { Copy-Item -LiteralPath $from -Destination $to -Force }
    }
}

# --------------------------------------------------------------- compile ----

function Ensure-ps2exe {
    if (Get-Module -ListAvailable -Name ps2exe) {
        Import-Module ps2exe -Force
        return $true
    }
    try {
        Say '       memasang modul ps2exe (CurrentUser)...'
        if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
        }
        Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop
        Import-Module ps2exe -Force
        return $true
    }
    catch {
        Say "       ps2exe tak dapat dipasang: $($_.Exception.Message)" 'Yellow'
        return $false
    }
}

function Compile-Exe {
    if (-not (Ensure-ps2exe)) { return $false }
    $common = @{
        title       = 'videoStitch'
        product     = 'videoStitch'
        company     = 'RafieRosliputra'
        description = 'Cantum banyak klip video jadi satu'
        version     = $Version
    }
    try {
        Say '       compile stitch.exe (CLI)...'
        Invoke-PS2EXE -InputFile (Join-Path $Target 'bin\stitch.ps1') -OutputFile (Join-Path $Target 'stitch.exe') @common
        Say '       compile VideoStitch.exe (GUI)...'
        try {
            Invoke-PS2EXE -InputFile (Join-Path $Target 'gui\VideoStitchGUI.ps1') -OutputFile (Join-Path $Target 'VideoStitch.exe') -noConsole -STA @common
        }
        catch {
            Say "       -STA tak disokong, cuba tanpa: $($_.Exception.Message)" 'Yellow'
            Invoke-PS2EXE -InputFile (Join-Path $Target 'gui\VideoStitchGUI.ps1') -OutputFile (Join-Path $Target 'VideoStitch.exe') -noConsole @common
        }
        return (Test-Path -LiteralPath (Join-Path $Target 'VideoStitch.exe'))
    }
    catch {
        Say "       compile gagal: $($_.Exception.Message)" 'Yellow'
        return $false
    }
}

function New-FallbackLauncher {
    $path = Join-Path $Target 'VideoStitch.cmd'
    $body = "@echo off`r`nstart `"`" `"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"%~dp0gui\VideoStitchGUI.ps1`"`r`n"
    if ($DryRun) { Say "       (dry) tulis VideoStitch.cmd (fallback)" }
    else { [System.IO.File]::WriteAllText($path, $body, [System.Text.Encoding]::ASCII) }
}

# ----------------------------------------------------------------- ffmpeg ---

function Ensure-FFmpeg {
    $ff = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($ff) { Say "       ffmpeg: $($ff.Source)" 'Green'; return $true }
    $link = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'
    if (Test-Path -LiteralPath $link) { Say "       ffmpeg: $link" 'Green'; return $true }
    if ($NoFFmpeg -or $DryRun) { Say '       ffmpeg tiada (dilangkau)' 'Yellow'; return $false }
    $ans = Read-Host '       ffmpeg tiada. Pasang sekarang guna winget? (y/N)'
    if ($ans -notmatch '^[yY]') { Say '       Langkau. Pasang manual: winget install -e --id Gyan.FFmpeg' 'Yellow'; return $false }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Say '       winget tiada. Pasang "App Installer" dari Microsoft Store dahulu.' 'Yellow'
        return $false
    }
    & winget install -e --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
    $ok = [bool](Get-Command ffmpeg -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath $link)
    if ($ok) { Say '       ffmpeg selesai dipasang.' 'Green' } else { Say '       winget tak berjaya; pasang manual.' 'Yellow' }
    return $ok
}

# ---------------------------------------------------------------- shortcut --

function New-Shortcut {
    param([string] $Path, [string] $TargetPath, [string] $WorkDir, [string] $Icon)
    if ($DryRun) { Say "       (dry) shortcut $Path -> $TargetPath"; return }
    $shell = New-Object -ComObject WScript.Shell
    $s = $shell.CreateShortcut($Path)
    $s.TargetPath = $TargetPath
    $s.WorkingDirectory = $WorkDir
    if ($Icon) { $s.IconLocation = "$Icon,0" }
    $s.Description = 'videoStitch - cantum video'
    $s.Save()
}

function Install-Shortcuts {
    $exe = Join-Path $Target 'VideoStitch.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $Target 'VideoStitch.cmd' }
    if (-not (Test-Path -LiteralPath $exe) -and -not $DryRun) { Say '       tiada launcher; shortcut dilangkau' 'Yellow'; return }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $programs = [Environment]::GetFolderPath('Programs')
    if (-not $desktop) {
        if ($DryRun) { $desktop = Join-Path $Target 'Desktop' } else { Say '       folder Desktop tiada; shortcut dilangkau' 'Yellow'; return }
    }
    if (-not $programs) {
        if ($DryRun) { $programs = Join-Path $Target 'Programs' } else { Say '       folder Start Menu tiada; shortcut dilangkau' 'Yellow'; return }
    }
    $startMenu = Join-Path $programs 'videoStitch'
    if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $startMenu | Out-Null }
    New-Shortcut -Path (Join-Path $desktop 'videoStitch.lnk') -TargetPath $exe -WorkDir $Target -Icon $exe
    New-Shortcut -Path (Join-Path $startMenu 'videoStitch.lnk') -TargetPath $exe -WorkDir $Target -Icon $exe
    Say "       Desktop + Start Menu: ok" 'Green'
}

# -------------------------------------------------------------- uninstall ---

function Register-Uninstall {
    if ($DryRun) { Say '       (dry) daftar HKCU Uninstall\videoStitch'; return }
    if (-not $isWin) { Say '       bukan Windows; daftar dilangkau' 'Yellow'; return }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\videoStitch'
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -Path $key -Name DisplayName     -Value 'videoStitch'
    Set-ItemProperty -Path $key -Name DisplayVersion  -Value $Version
    Set-ItemProperty -Path $key -Name Publisher       -Value 'RafieRosliputra'
    Set-ItemProperty -Path $key -Name InstallLocation -Value $Target
    Set-ItemProperty -Path $key -Name UninstallString -Value ('"' + $env:SystemRoot + '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Target 'uninstall.ps1') + '"')
    Set-ItemProperty -Path $key -Name DisplayIcon     -Value (Join-Path $Target 'VideoStitch.exe')
    Set-ItemProperty -Path $key -Name NoModify -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name NoRepair -Value 1 -Type DWord
    Say '       Settings > Apps: videoStitch didaftarkan' 'Green'
}

# ------------------------------------------------------------------- main ---

Say ''
Say '  videoStitch - pemasang' 'White'
Say "  sumber : $src"
Say "  target : $Target"
Say ''

Step 1 'Semak payload'
if (-not (Test-Path -LiteralPath (Join-Path $src 'bin/stitch.ps1'))) { throw "Fail bin/stitch.ps1 tiada dalam $src" }
if (-not (Test-Path -LiteralPath (Join-Path $src 'gui/VideoStitchGUI.ps1'))) { throw "Fail gui/VideoStitchGUI.ps1 tiada dalam $src" }
Say '       ok' 'Green'

Step 2 'Salin fail'
if ($isWin -and -not $DryRun) {
    Get-Process -Name 'VideoStitch' -ErrorAction SilentlyContinue | ForEach-Object {
        try { [void] $_.CloseMainWindow(); Start-Sleep -Milliseconds 400; if (-not $_.HasExited) { Stop-Process -Id $_.Id -Force } } catch { }
    }
}
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $Target | Out-Null }
Copy-Payload
if (-not $DryRun) {
    [System.IO.File]::WriteAllText((Join-Path $Target 'version.txt'), $Version, [System.Text.Encoding]::ASCII)
}
Say '       ok' 'Green'

Step 3 'Compile .exe'
if ($NoCompile) { Say '       dilangkau (-NoCompile)' 'Yellow'; New-FallbackLauncher }
elseif ($DryRun) { Say '       (dry) compile dilangkau' }
elseif (Compile-Exe) { Say '       VideoStitch.exe + stitch.exe siap' 'Green' }
else { Say '       guna launcher fallback (VideoStitch.cmd)' 'Yellow'; New-FallbackLauncher }

Step 4 'ffmpeg'
[void] (Ensure-FFmpeg)

Step 5 'Shortcut'
if ($NoShortcuts) { Say '       dilangkau (-NoShortcuts)' 'Yellow' } else { Install-Shortcuts }

Step 6 'Daftar uninstall'
Register-Uninstall

Say ''
Say '  Siap.' 'Green'
Say "  Buka: $Target"
Say '  Uninstall: Settings > Apps > videoStitch, atau jalankan uninstall.ps1 dalam folder tu.'
Say ''

if ($isWin -and -not $DryRun) {
    $ans = Read-Host 'Buka videoStitch sekarang? (Y/n)'
    if ($ans -notmatch '^[nN]') {
        $exe = Join-Path $Target 'VideoStitch.exe'
        if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -WorkingDirectory $Target | Out-Null }
        else { Start-Process -FilePath (Join-Path $Target 'VideoStitch.cmd') -WorkingDirectory $Target | Out-Null }
    }
}
