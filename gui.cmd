@echo off
rem videoStitch - GUI launcher (double-click)
setlocal
set DIR=%~dp0
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
  echo PowerShell tidak dijumpai.
  pause & exit /b 1
)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%DIR%gui\VideoStitchGUI.ps1"
