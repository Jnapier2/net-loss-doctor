#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$powerShellFiles = @(Get-ChildItem -LiteralPath $repo -Filter '*.ps1' -Recurse -File)
Assert-True ($powerShellFiles.Count -ge 3) 'Expected the two application scripts and this policy test.'

foreach ($file in $powerShellFiles) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    Assert-True ($errors.Count -eq 0) ("PowerShell parse errors in {0}: {1}" -f $file.FullName, (($errors | ForEach-Object Message) -join '; '))
}

$enginePath = Join-Path $repo 'NetLossDoctor.ps1'
$comparePath = Join-Path $repo 'Compare-NetLossDoctorReports.ps1'
$engine = Get-Content -LiteralPath $enginePath -Raw
$compare = Get-Content -LiteralPath $comparePath -Raw
$metadataPath = Join-Path $repo 'PUBLIC_SOURCE_METADATA.json'
Assert-True (Test-Path -LiteralPath $metadataPath -PathType Leaf) 'Public source metadata is missing.'
$publicMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
Assert-True ($publicMetadata.build_id -eq 'NLD-2.10.0-PUBLIC-20260810-02') 'Public source build ID changed.'
Assert-True ($publicMetadata.parameter_baseline -eq '2.17.9') 'Parameter baseline is not aligned to 2.17.9.'
Assert-True ($publicMetadata.parameter_package_sha256 -eq 'fafe3f4a972b1f4def6e10faee7febc3c75154b8b346949991bb9d86e8a610df') 'Parameter package checksum changed.'
Assert-True ($publicMetadata.canonical_entrypoint -eq 'Start-NetLossDoctor.cmd') 'Canonical entrypoint metadata changed.'
Assert-True ($publicMetadata.backend_target -eq 'NetLossDoctor.ps1') 'Backend-target metadata changed.'
Assert-True ($publicMetadata.comparison_helper -eq 'Compare-NetLossDoctorReports.ps1') 'Comparison-helper metadata changed.'
Assert-True ($publicMetadata.relative_reports_root_policy -eq 'rebase_from_resolved_project_root') 'Relative report-root policy changed.'
Assert-True (@($publicMetadata.runtime_owned_output_roots) -contains 'exports/NetLossDoctor_Reports') 'Project-local output metadata changed.'
Assert-True ($publicMetadata.output_failure_policy -eq 'fail_closed_no_cwd_desktop_or_os_temp_final_output_fallback') 'Output failure policy changed.'
Assert-True ($publicMetadata.runtime_identity_gate.status -eq 'not_required_for_current_public_source') 'Runtime identity applicability boundary changed.'
Assert-True (-not [bool]$publicMetadata.user_profile_fallback_allowed) 'User-profile fallback must remain disabled.'
Assert-True ([int]$publicMetadata.file_inventory_and_consolidation.canonical_launcher_count -eq 1) 'Canonical launcher inventory changed.'
Assert-True ([int]$publicMetadata.file_inventory_and_consolidation.exact_duplicate_files_detected -eq 0) 'Exact duplicate inventory changed.'
Assert-True ([bool]$publicMetadata.launch_verification.root_relative) 'Root-relative launcher metadata is missing.'
Assert-True ([bool]$publicMetadata.launch_verification.argument_forwarding) 'Launcher argument-forwarding metadata is missing.'
Assert-True ([bool]$publicMetadata.launch_verification.foreign_working_directory_ci) 'Foreign-working-directory launch verification metadata is missing.'
Assert-True (-not [bool]$publicMetadata.launch_verification.caller_working_directory_output_allowed) 'Caller-CWD output must remain disabled.'
Assert-True ($engine -match "\[string\]\`$Mode\s*=\s*'doctor'") 'Default mode must remain the local doctor self-test.'
Assert-True ($engine -match '\[switch\]\$EnablePktmon') 'Pktmon must retain an explicit opt-in switch.'
Assert-True ($engine -match '-Skip:\(-not \$EnablePktmon\)') 'Pktmon must remain skipped unless explicitly enabled.'
Assert-True ($engine -notmatch "@\('filter','remove'\)") 'Pktmon must never remove every filter.'
Assert-True ($engine -match "@\('filter','remove',\`$filterName\)") 'Pktmon cleanup must remove only its named filters.'
Assert-True ($engine -match "Name='NetLossDoctor-ICMP'" -and $engine -match "Name='NetLossDoctor-DNS'") 'Pktmon filters must remain uniquely named.'
Assert-True ($engine -match '(?s)function Stop-PktmonSession.+?finally\s*\{.+?pktmon_finally_stop.+?pktmon_filter_remove_') 'Pktmon stop and named-filter cleanup must remain in finally.'
Assert-True ($engine -match '(?s)function Stop-NetshTraceSession.+?finally\s*\{.+?netsh_trace_finally_stop') 'netsh trace stop must retain a finally fallback.'
Assert-True ($engine -match '(?s)try\s*\{\s*\$pktmonState = Start-PktmonSession.+?\$netshTraceState = Start-NetshTraceSession.+?finally\s*\{\s*try \{ \$pktmonState = Stop-PktmonSession.+?try \{ \$netshTraceState = Stop-NetshTraceSession') 'The capture lifecycle must remain enclosed by outer try/finally cleanup.'

$allText = ($powerShellFiles | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
Assert-True ($allText -notmatch '(?i)ExecutionPolicy\s+Bypass') 'Execution-policy bypasses are not permitted in tracked source.'

$runtimeText = $engine + "`n" + $compare
foreach ($stalePattern in @('(?i)signal.?booster','(?i)NetLossDoctor\.bat','(?i)menu option','\$NoPktmon','\$FullRawZip','\$Topology','FileDownloadThrottle','DownloadThrottleMbps','Export20','MANIFEST\.json','Asset-ID','PackageVersion','sensitive_redacted')) {
    Assert-True ($runtimeText -notmatch $stalePattern) ("Stale package/runtime term found: $stalePattern")
}
Assert-True ($runtimeText -notmatch '(?i)Set-Clipboard') 'Diagnostics must not alter clipboard contents.'
Assert-True ($engine -match 'Sensitivity: support-redacted') 'Generated support metadata must remain labeled support-redacted.'
Assert-True ($engine -match 'EXPORT_CONTENTS\.txt') 'Support archives must retain a plain-language contents file.'
Assert-True ($engine -match "\$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-02'") 'Transparent public build ID is missing.'
Assert-True ($engine -notmatch 'current_working_directory_fallback') 'Caller CWD must not be project-root authority.'
Assert-True ($engine -notmatch '\$baseDir = Join-Path \$desktop ''NetLossDoctor_Reports''') 'Desktop must not be a final-output fallback.'
Assert-True ($engine -notmatch '\$baseDir = Join-Path \$env:TEMP ''NetLossDoctor_Reports''') 'OS temp must not be a final-output fallback.'
Assert-True ($engine -match 'No Desktop or OS-temp fallback will be used') 'Fail-closed output error is missing.'
Assert-True ($engine -match 'New-Item -ItemType Directory -Path \$Path -Force -ErrorAction Stop') 'Directory creation must be terminating so fail-closed handling can run.'
Assert-True ($compare -match "\$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-02'") 'Comparison helper build ID is missing.'
Assert-True ($compare -notmatch '\(Get-Location\)\.Path') 'Comparison helper must not use caller CWD as project-root authority.'
Assert-True ($compare -match '\[IO\.Path\]::IsPathRooted\(\$ReportsPath\)') 'Relative comparison paths must be identified before rebasing.'
Assert-True ($compare -match 'New-Item -ItemType Directory -Path \$ReportsPath -Force -ErrorAction Stop') 'Comparison output creation must be terminating.'
Assert-True ($compare -match 'No caller-CWD, Desktop, or OS-temp fallback will be used') 'Comparison fail-closed output error is missing.'

$forbiddenCommands = @(
    'Set-NetAdapter', 'Disable-NetAdapter', 'Enable-NetAdapter', 'Restart-NetAdapter',
    'Set-DnsClientServerAddress', 'New-NetFirewallRule', 'Remove-NetFirewallRule',
    'Set-NetFirewallRule', 'Set-NetIPInterface', 'Set-NetOffloadGlobalSetting',
    'Set-NetTCPSetting', 'Add-MpPreference', 'Set-MpPreference'
)

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($enginePath, [ref]$tokens, [ref]$errors)
$commands = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
foreach ($name in $forbiddenCommands) {
    Assert-True ($name -notin $commands) ("Forbidden system-mutating command found: $name")
}

# Load only the redactor and cleanup functions from the parsed source. This tests the
# safety primitives without executing the diagnostic or changing policy.
foreach ($functionName in @('Redact-NldExportText','Stop-PktmonSession','Stop-NetshTraceSession')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Assert-True ($null -ne $definition) ("Required function not found: $functionName")
    . ([ScriptBlock]::Create($definition.Extent.Text))
}

$Script:ToolRoot = $repo
$runDir = Join-Path $repo 'synthetic-report-path'
$oldUser = $env:USERNAME
$oldComputer = $env:COMPUTERNAME
try {
    $env:USERNAME = 'SyntheticUserFixture'
    $env:COMPUTERNAME = 'SYNTHETIC-HOST-FIXTURE'
    # Assemble the synthetic Windows profile path at runtime so the repository
    # never contains a real user-shaped absolute path literal.
    $fixtureUserPath = 'C:' + '\Users\' + $env:USERNAME
    $fixture = @"
IPv4A=10.23.45.67
IPv4B=172.16.9.8
IPv4C=192.168.44.55
IPv6A=2001:db8::1234
IPv6B=fe80::abcd%12
Path=$fixtureUserPath\Documents\private.txt
MAC=00-11-22-33-44-55
SSID=Private Lab WiFi
BSSID=66:77:88:99:aa:bb
UserName=SyntheticUserFixture
ComputerName=SYNTHETIC-HOST-FIXTURE
"@
    $redacted = Redact-NldExportText -Text $fixture
    foreach ($secret in @('10.23.45.67','172.16.9.8','192.168.44.55','2001:db8::1234','fe80::abcd%12',$fixtureUserPath,'00-11-22-33-44-55','Private Lab WiFi','66:77:88:99:aa:bb','SyntheticUserFixture','SYNTHETIC-HOST-FIXTURE')) {
        Assert-True ($redacted -notmatch [Regex]::Escape($secret)) ("Redaction leaked fixture value: $secret")
    }
    foreach ($marker in @('<PRIVATE_IP_REDACTED>','<IPV6_REDACTED>','<LOCAL_PATH>','<MAC_REDACTED>','<SSID_REDACTED>','<USER_REDACTED>','<COMPUTER_REDACTED>')) {
        Assert-True ($redacted -match [Regex]::Escape($marker)) ("Expected redaction marker missing: $marker")
    }
} finally {
    $env:USERNAME = $oldUser
    $env:COMPUTERNAME = $oldComputer
}

$script:CleanupCalls = @()
function Invoke-LoggedCommand {
    param([string]$Name,[string]$Command,[string[]]$Arguments,[int]$TimeoutSec,[string]$OutputDir)
    $script:CleanupCalls += [PSCustomObject]@{ Name=$Name; Command=$Command; Arguments=@($Arguments) }
    return [PSCustomObject]@{ File=('synthetic-' + $Name + '.txt'); ExitCode=0; TimedOut=$false; Output='synthetic success' }
}
$pktmonDir = Join-Path $repo 'synthetic-pktmon'
$pktState = [PSCustomObject]@{ Started=$true; EtlFile=$null; FilterNames=@('NetLossDoctor-ICMP','NetLossDoctor-DNS'); Notes=@(); Files=@() }
$pktState = Stop-PktmonSession -State $pktState
Assert-True (-not $pktState.Started -and $pktState.FilterNames.Count -eq 0) 'Pktmon cleanup must clear running and owned-filter state.'
foreach ($filterName in @('NetLossDoctor-ICMP','NetLossDoctor-DNS')) {
    Assert-True (@($script:CleanupCalls | Where-Object { ($_.Arguments -join ' ') -eq ('filter remove ' + $filterName) }).Count -eq 1) ("Named Pktmon filter was not removed: $filterName")
}
Assert-True (@($script:CleanupCalls | Where-Object { ($_.Arguments -join ' ') -eq 'filter remove' }).Count -eq 0) 'Cleanup must not issue an unscoped Pktmon filter removal.'

$script:CleanupCalls = @()
$netshTraceDir = Join-Path $repo 'synthetic-netsh'
$netshState = [PSCustomObject]@{ Started=$true; EtlFile=$null; Notes=@(); Files=@() }
$netshState = Stop-NetshTraceSession -State $netshState
Assert-True (-not $netshState.Started) 'netsh cleanup must clear running state.'
Assert-True (@($script:CleanupCalls | Where-Object { ($_.Arguments -join ' ') -eq 'trace stop' }).Count -ge 1) 'netsh cleanup must issue trace stop.'

# Capture stop commands report failures through ExitCode/TimedOut rather than
# exceptions. Exercise nonzero and timeout results for both cleanup functions.
$script:CleanupScenario = ''
function Invoke-LoggedCommand {
    param([string]$Name,[string]$Command,[string[]]$Arguments,[int]$TimeoutSec,[string]$OutputDir)
    $script:CleanupCalls += [PSCustomObject]@{ Name=$Name; Command=$Command; Arguments=@($Arguments) }
    $exitCode = 0
    $timedOut = $false
    if ($script:CleanupScenario -eq 'pktmon_nonzero' -and $Name -eq 'pktmon_stop') { $exitCode = 5 }
    if ($script:CleanupScenario -eq 'pktmon_timeout' -and $Name -in @('pktmon_stop','pktmon_finally_stop')) { $exitCode = -1; $timedOut = $true }
    if ($script:CleanupScenario -eq 'netsh_nonzero' -and $Name -eq 'netsh_trace_stop') { $exitCode = 5 }
    if ($script:CleanupScenario -eq 'netsh_timeout' -and $Name -in @('netsh_trace_stop','netsh_trace_finally_stop')) { $exitCode = -1; $timedOut = $true }
    return [PSCustomObject]@{ File=('synthetic-' + $Name + '.txt'); ExitCode=$exitCode; TimedOut=$timedOut; Output='synthetic result' }
}

$script:CleanupScenario = 'pktmon_nonzero'
$script:CleanupCalls = @()
$pktState = [PSCustomObject]@{ Started=$true; EtlFile=$null; FilterNames=@(); Notes=@(); Files=@() }
$pktState = Stop-PktmonSession -State $pktState
Assert-True (-not $pktState.Started) 'Pktmon nonzero primary stop must be retried and cleared only after retry success.'
Assert-True (@($script:CleanupCalls | Where-Object Name -eq 'pktmon_finally_stop').Count -eq 1) 'Pktmon nonzero primary stop did not trigger the cleanup retry.'

$script:CleanupScenario = 'pktmon_timeout'
$script:CleanupCalls = @()
$pktState = [PSCustomObject]@{ Started=$true; EtlFile=$null; FilterNames=@(); Notes=@(); Files=@() }
$pktState = Stop-PktmonSession -State $pktState
Assert-True ($pktState.Started) 'Pktmon state must remain active when both primary and retry stops time out.'
Assert-True (@($script:CleanupCalls | Where-Object Name -eq 'pktmon_finally_stop').Count -eq 1) 'Pktmon timeout did not trigger the cleanup retry.'

$script:CleanupScenario = 'netsh_nonzero'
$script:CleanupCalls = @()
$netshState = [PSCustomObject]@{ Started=$true; EtlFile=$null; Notes=@(); Files=@() }
$netshState = Stop-NetshTraceSession -State $netshState
Assert-True (-not $netshState.Started) 'netsh nonzero primary stop must be retried and cleared only after retry success.'
Assert-True (@($script:CleanupCalls | Where-Object Name -eq 'netsh_trace_finally_stop').Count -eq 1) 'netsh nonzero primary stop did not trigger the cleanup retry.'

$script:CleanupScenario = 'netsh_timeout'
$script:CleanupCalls = @()
$netshState = [PSCustomObject]@{ Started=$true; EtlFile=$null; Notes=@(); Files=@() }
$netshState = Stop-NetshTraceSession -State $netshState
Assert-True ($netshState.Started) 'netsh state must remain active when both primary and retry stops time out.'
Assert-True (@($script:CleanupCalls | Where-Object Name -eq 'netsh_trace_finally_stop').Count -eq 1) 'netsh timeout did not trigger the cleanup retry.'

$crossCwd = Join-Path ([IO.Path]::GetTempPath()) ('NetLossDoctor_CrossCwd_' + [guid]::NewGuid().ToString('N'))
$oldLocation = Get-Location
$oldNldHome = $env:NLD_HOME
try {
    New-Item -ItemType Directory -Path $crossCwd -Force | Out-Null
    $env:NLD_HOME = Join-Path $crossCwd 'stale-home'
    Set-Location -LiteralPath $crossCwd
    $dryOutput = (& powershell.exe -NoLogo -NoProfile -File $enginePath -Mode standard -DryRun 2>&1 | Out-String)
    $dryExit = $LASTEXITCODE
    Assert-True ($dryExit -eq 0) ("Cross-working-directory dry run failed with exit code {0}: {1}" -f $dryExit, $dryOutput)
    $expectedRoot = [IO.Path]::GetFullPath($repo)
    $expectedReports = Join-Path (Join-Path $expectedRoot 'exports') 'NetLossDoctor_Reports'
    Assert-True ($dryOutput -match [Regex]::Escape("Tool root resolved: $expectedRoot")) 'Dry run did not resolve the tool root from the script location.'
    Assert-True ($dryOutput -match [Regex]::Escape("ReportsRoot resolved: $expectedReports")) 'Dry run did not keep the default report root under the project folder.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $crossCwd 'exports'))) 'Caller CWD received an unexpected output directory.'
} finally {
    Set-Location -LiteralPath $oldLocation.Path
    $env:NLD_HOME = $oldNldHome
    Remove-Item -LiteralPath $crossCwd -Recurse -Force -ErrorAction SilentlyContinue
}

$compareFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('NetLossDoctor_CompareRoot_' + [guid]::NewGuid().ToString('N'))
$compareToolRoot = Join-Path $compareFixtureRoot 'tool-root'
$compareCallerRoot = Join-Path $compareFixtureRoot 'caller-root'
$oldLocation = Get-Location
$oldNldHome = $env:NLD_HOME
try {
    New-Item -ItemType Directory -Path $compareToolRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $compareCallerRoot -Force | Out-Null
    Copy-Item -LiteralPath $comparePath -Destination (Join-Path $compareToolRoot 'Compare-NetLossDoctorReports.ps1') -Force
    $env:NLD_HOME = Join-Path $compareFixtureRoot 'stale-home'
    Set-Location -LiteralPath $compareCallerRoot
    $copiedCompare = Join-Path $compareToolRoot 'Compare-NetLossDoctorReports.ps1'
    $compareOutput = (& powershell.exe -NoLogo -NoProfile -File $copiedCompare -Days 1 2>&1 | Out-String)
    $compareExit = $LASTEXITCODE
    Assert-True ($compareExit -eq 0) ("Cross-working-directory comparison failed with exit code {0}: {1}" -f $compareExit, $compareOutput)
    $expectedCompareReports = Join-Path (Join-Path $compareToolRoot 'exports') 'NetLossDoctor_Reports'
    Assert-True (Test-Path -LiteralPath $expectedCompareReports -PathType Container) 'Comparison helper did not create its report root under the copied project folder.'
    Assert-True (@(Get-ChildItem -LiteralPath $expectedCompareReports -Filter 'NetLossDoctor_Comparison_*.txt' -File).Count -eq 1) 'Comparison helper did not publish one text result under the project-local report root.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $compareCallerRoot 'exports'))) 'Comparison helper wrote output beneath caller CWD.'
} finally {
    Set-Location -LiteralPath $oldLocation.Path
    $env:NLD_HOME = $oldNldHome
    Remove-Item -LiteralPath $compareFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("PASS: parsed {0} PowerShell files and verified safety invariants." -f $powerShellFiles.Count) -ForegroundColor Green
