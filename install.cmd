@echo off
rem videoStitch - pemasang (double-click). Semua kerja dibuat oleh install\install.ps1
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" (echo PowerShell tidak dijumpai. & pause & exit /b 1)
"%PS%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0install\install.ps1" %*
echo.
pause
