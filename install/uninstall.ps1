<#
.SYNOPSIS
    Nyahpasang videoStitch (per-user).
.PARAMETER Force
    Jangan tanya pengesahan.
#>
[CmdletBinding()]
param([switch] $Force)

$ErrorActionPreference = 'Stop'
$Target = $PSScriptRoot

if (-not $Force) {
    $ans = Read-Host "Nyahpasang videoStitch dari '$Target'? (y/N)"
    if ($ans -notmatch '^[yY]') { Write-Host 'Dibatalkan.'; return }
}

# 1) shortcut
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path ([Environment]::GetFolderPath('Programs')) 'videoStitch'
foreach ($p in @(
        (Join-Path $desktop 'videoStitch.lnk'),
        (Join-Path $startMenu 'videoStitch.lnk'))) {
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Host "dibuang: $p" }
}
if (Test-Path -LiteralPath $startMenu) { Remove-Item -LiteralPath $startMenu -Recurse -Force -ErrorAction SilentlyContinue }

# 2) registry
$key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\videoStitch'
if (Test-Path $key) { Remove-Item -Path $key -Recurse -Force; Write-Host 'didaftar: dibuang dari Settings > Apps' }

# 3) proses yang masih berjalan
Get-Process -Name 'VideoStitch' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

# 4) folder — skrip ini sendiri ada dalam folder, jadi jadualkan pemadaman selepas keluar
if ((Resolve-Path $Target).Path -eq (Resolve-Path $PSScriptRoot).Path -and $PSScriptRoot) {
    $cmd = 'Start-Sleep -Milliseconds 600; Remove-Item -LiteralPath ''' + $Target + ''' -Recurse -Force -ErrorAction SilentlyContinue'
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-Command', $cmd) | Out-Null
    Write-Host 'Folder akan dibuang selepas tetingkap ini ditutup.'
}
else {
    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Folder dibuang.'
}

Write-Host 'Siap nyahpasang.'
