@echo off
rem videoStitch - CLI launcher: stitch.cmd [args untuk bin\stitch.ps1]
setlocal
set DIR=%~dp0
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%DIR%bin\stitch.ps1" %*
