#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$launcherPath = Join-Path $repo 'Start-NetLossDoctor.cmd'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Assert-True (Test-Path -LiteralPath $launcherPath -PathType Leaf) 'The canonical Start-NetLossDoctor.cmd launcher is missing.'
$launcher = Get-Content -LiteralPath $launcherPath -Raw

Assert-True ($launcher -match 'cd /d "%~dp0"') 'The launcher must derive its working directory from its own location.'
Assert-True ($launcher -match 'NetLossDoctor\.ps1') 'The launcher must delegate to the NetLossDoctor PowerShell engine.'
Assert-True ($launcher -match 'powershell\.exe -NoLogo -NoProfile -File') 'The launcher must use the supported Windows PowerShell path.'
Assert-True ($launcher -match '%\*') 'The launcher must forward explicit command-line parameters.'
Assert-True ($launcher -notmatch '(?i)ExecutionPolicy\s+Bypass') 'The launcher must not bypass local execution-policy controls.'
Assert-True ($launcher -notmatch '(?im)^\s*:menu\b|choice\s+/c') 'The launcher must remain a thin forwarder without duplicate menu logic.'

$rootLaunchers = @(Get-ChildItem -LiteralPath $repo -File | Where-Object { $_.Extension -in @('.bat','.cmd') })
Assert-True ($rootLaunchers.Count -eq 1) ('Expected one root launcher, found: ' + (($rootLaunchers | ForEach-Object Name) -join ', '))

Write-Host 'PASS: NetLossDoctor canonical launcher is root-relative, thin, and parameter-forwarding.' -ForegroundColor Green
