@echo off
REM Copyright 2026 Gateway Information Group LLC. All rights reserved.
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0" || (
  echo ERROR: The NetLossDoctor project folder could not be opened.
  exit /b 2
)

set "NLD_SCRIPT=%~dp0NetLossDoctor.ps1"
if not exist "%NLD_SCRIPT%" (
  echo ERROR: NetLossDoctor.ps1 is missing beside this launcher.
  exit /b 2
)

where powershell.exe >nul 2>&1 || (
  echo ERROR: Windows PowerShell 5.1 was not found on PATH.
  exit /b 3
)

powershell.exe -NoLogo -NoProfile -File "%NLD_SCRIPT%" %*
exit /b %errorlevel%
