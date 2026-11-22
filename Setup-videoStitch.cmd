@echo off
rem videoStitch - pemasang SATU FAIL.
rem Muat turun setup.ps1 dari GitHub, kemudian ia ambil zip rilis terbaharu.
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "RAW=https://raw.githubusercontent.com/RafieRosliputra/videoStichWinCLIGUI/main/setup.ps1"
set "TMP=%TEMP%\videoStitch-boot"
if not exist "%PS%" (echo PowerShell tidak dijumpai. & pause & exit /b 1)
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -Command "& { $ErrorActionPreference='Stop'; if (Test-Path $env:TEMP\videoStitch-boot) { Remove-Item $env:TEMP\videoStitch-boot -Recurse -Force }; New-Item -ItemType Directory -Force -Path $env:TEMP\videoStitch-boot | Out-Null; $s = Join-Path $env:TEMP 'videoStitch-boot\setup.ps1'; Invoke-WebRequest -UseBasicParsing -Uri '%RAW%' -OutFile $s; & $s }"
echo.
pause
