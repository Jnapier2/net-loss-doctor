@echo off
setlocal
where powershell.exe >nul 2>&1 || (
  echo Windows PowerShell was not found on PATH.
  exit /b 2
)
powershell.exe -NoLogo -NoProfile -File "%~dp0NetLossDoctor.ps1" %*
exit /b %ERRORLEVEL%
