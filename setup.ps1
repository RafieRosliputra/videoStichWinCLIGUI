<#
.SYNOPSIS
    Pemasang satu-fail: muat turun zip rilis terbaharu, extract, jalankan install.ps1.
.DESCRIPTION
    Dipanggil oleh Setup-videoStitch.cmd (atau terus: powershell -File setup.ps1).
#>
[CmdletBinding()]
param(
    [string] $ZipUrl = 'https://github.com/RafieRosliputra/videoStichWinCLIGUI/releases/latest/download/videoStitch-latest.zip',
    [string] $WorkDir,
    [switch] $DryRun,
    [switch] $NoCompile,
    [switch] $NoFFmpeg
)

$ErrorActionPreference = 'Stop'
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) 'videoStitch-setup' }

Write-Host "videoStitch setup" -ForegroundColor Cyan
Write-Host "  zip   : $ZipUrl"
Write-Host "  kerja : $WorkDir"

if ($DryRun) { Write-Host '  (dry) tiada muat turun'; exit 0 }
if (-not ($env:OS -eq 'Windows_NT')) { throw 'setup.ps1 untuk Windows sahaja.' }

if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$zip = Join-Path $WorkDir 'videoStitch.zip'
Write-Host '[1/3] Muat turun...' -ForegroundColor Cyan
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri $ZipUrl -OutFile $zip
Write-Host ('      {0:N1} MB' -f ((Get-Item -LiteralPath $zip).Length / 1MB))

Write-Host '[2/3] Extract...' -ForegroundColor Cyan
Expand-Archive -LiteralPath $zip -DestinationPath $WorkDir -Force
$root = Get-ChildItem -LiteralPath $WorkDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'install\install.ps1') } | Select-Object -First 1
if (-not $root) { throw 'Struktur zip tidak dijangka: install\install.ps1 tiada.' }

Write-Host '[3/3] Jalankan pemasang...' -ForegroundColor Cyan
$argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $root.FullName 'install\install.ps1'))
if ($NoCompile) { $argList += '-NoCompile' }
if ($NoFFmpeg)  { $argList += '-NoFFmpeg' }
& powershell.exe @argList
