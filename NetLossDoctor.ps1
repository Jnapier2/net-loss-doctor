# NetLossDoctor v2.10.0
# Read-only Windows network diagnostics with bounded, redacted support exports.

param(
    [ValidateSet('quick','standard','full','observe','appcheck','doctor','help')]
    [string]$Mode = 'doctor',
    [int]$Count = 0,
    [int]$DurationSeconds = 0,
    [string]$Label = 'BASELINE',
    [switch]$NoZip,
    [switch]$EnablePktmon,
    [switch]$NoLoad,
    [switch]$NetshTrace,
    [string]$ExtraTargets = '',
    [ValidateRange(0,100000)]
    [double]$LoadRateLimitMbps = 0,
    [int]$LoadBytes = 25000000,
    [int]$ExportFileLimit = 20,
    [string]$ReportsRoot = '',
    [switch]$DryRun
)

$Script:Version = '2.10.0'
$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-01'
$Script:ParameterBaseline = '2.17.6'
$Script:ProjectSlug = 'netlossdoctor'
$Script:ReleaseStatus = 'current'
$Script:NetworkResearchReviewDate = '2026-07-18'
$Script:NetworkResearchStatus = 'verified_official_microsoft_sources'
$Script:StartTime = Get-Date
$Script:RunStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$Script:CurrentStage = 'initializing'
$Script:LastProgressTime = $Script:StartTime
$Script:ToolRootResolutionNote = 'not_resolved'
$ErrorActionPreference = 'Continue'
$Script:HandledNonFatalWarnings = New-Object System.Collections.Generic.List[string]

if ($Mode -eq 'help') {
@"
NetLossDoctor $Script:Version

Usage:
  .\NetLossDoctor.ps1                                    Local self-test; no network probes
  .\NetLossDoctor.ps1 -Mode quick                        Short active network baseline
  .\NetLossDoctor.ps1 -Mode standard                     Recommended normal baseline diagnostic
  .\NetLossDoctor.ps1 -Mode observe -DurationSeconds 1800
  .\NetLossDoctor.ps1 -Mode full -NoLoad                 Broad diagnostic without a load test
  .\NetLossDoctor.ps1 -Mode full -LoadRateLimitMbps 10   Rate-limit the optional load test
  .\NetLossDoctor.ps1 -Mode full -NetshTrace             Opt-in advanced deep trace
  .\NetLossDoctor.ps1 -Mode standard -EnablePktmon       Opt-in Windows packet counters/capture
  .\NetLossDoctor.ps1 -Mode standard -Count 75           Overrides ping count per target
  .\NetLossDoctor.ps1 -Mode standard -ExtraTargets 75.75.75.75
  .\NetLossDoctor.ps1 -Mode standard -DryRun             Shows planned settings only

Export policy:
  Diagnostic and doctor runs create one compact *_SUPPORT_EXPORT.zip unless -NoZip is used.
  Review the archive before sharing it with a trusted support recipient.

Safety defaults:
  - Running without arguments performs the local doctor self-test.
  - Packet Monitor and netsh trace are disabled unless explicitly enabled.
  - The tool never changes adapters, routes, DNS, proxy, firewall, or TCP settings.
  - Clipboard contents are never changed.

Output:
  A report folder and ZIP are created under the project-local exports\NetLossDoctor_Reports folder by default. If you pass -ReportsRoot, relative paths are resolved from the tool folder.
"@ | Write-Host
    exit 0
}

if ($DryRun) {
    $dryScriptPath = $PSCommandPath
    if ([string]::IsNullOrWhiteSpace($dryScriptPath)) { $dryScriptPath = $MyInvocation.MyCommand.Path }
    $dryToolRoot = $null
    if (-not [string]::IsNullOrWhiteSpace($env:NLD_HOME) -and (Test-Path -LiteralPath (Join-Path $env:NLD_HOME 'NetLossDoctor.ps1'))) {
        try { $dryToolRoot = [IO.Path]::GetFullPath($env:NLD_HOME) } catch { $dryToolRoot = $env:NLD_HOME }
    } elseif (-not [string]::IsNullOrWhiteSpace($dryScriptPath)) {
        try { $dryToolRoot = [IO.Path]::GetFullPath((Split-Path -Parent $dryScriptPath)) } catch { $dryToolRoot = Split-Path -Parent $dryScriptPath }
    }
    if ([string]::IsNullOrWhiteSpace($dryToolRoot)) {
        Write-Error 'Unable to resolve the NetLossDoctor project root from NLD_HOME or the script location. No output was created.'
        exit 24
    }
    $dryReportsRoot = if ([string]::IsNullOrWhiteSpace($ReportsRoot)) { Join-Path (Join-Path $dryToolRoot 'exports') 'NetLossDoctor_Reports' } else {
        $expanded = [Environment]::ExpandEnvironmentVariables($ReportsRoot.Trim().Trim('"'))
        if ([IO.Path]::IsPathRooted($expanded)) { [IO.Path]::GetFullPath($expanded) } else { [IO.Path]::GetFullPath((Join-Path $dryToolRoot $expanded)) }
    }
@"
NetLossDoctor $Script:Version dry run preview

No diagnostics were executed and no report ZIP was created.

Planned settings:
  Mode: $Mode
  Count override: $Count
  DurationSeconds: $DurationSeconds
  Label: $Label
  LoadRateLimitMbps: $LoadRateLimitMbps
  NoZip: $NoZip
  EnablePktmon: $EnablePktmon
  NoLoad: $NoLoad
  NetshTrace: $NetshTrace
  ExtraTargets: $ExtraTargets
  LoadBytes: $LoadBytes
  ExportFileLimit requested: $ExportFileLimit
  ExportFileLimit enforced range: 10-20
  Tool root resolved: $dryToolRoot
  ReportsRoot resolved: $dryReportsRoot
  Dry run selected. No diagnostics were executed.
"@ | Write-Host
    exit 0
}

function Write-ConsoleLine {
    param([string]$Text = '')
    Write-Host $Text
}

function Set-NldProgress {
    param([string]$Stage)
    if ([string]::IsNullOrWhiteSpace($Stage)) { return }
    $Script:CurrentStage = $Stage
    $Script:LastProgressTime = Get-Date
}

function New-SafeFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'unknown' }
    $safe = ($Name -replace '[^a-zA-Z0-9_.-]+','_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = 'unknown' }
    if ($safe.Length -gt 90) { $safe = $safe.Substring(0,90) }
    return $safe
}

function New-DirectorySafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    }
}


function Resolve-NldFolderPath {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][string]$BasePath
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $candidate = [string]$Path
    try { $candidate = [Environment]::ExpandEnvironmentVariables($candidate) } catch {}
    $candidate = $candidate.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $null }
    try {
        if ($candidate -match '^[~]([\\/].*)?$') {
            $home = [Environment]::GetFolderPath('UserProfile')
            if (-not [string]::IsNullOrWhiteSpace($home)) {
                $tail = $candidate.Substring(1).TrimStart('\\','/')
                if ([string]::IsNullOrWhiteSpace($tail)) { $candidate = $home } else { $candidate = Join-Path $home $tail }
            }
        }
        if (-not [IO.Path]::IsPathRooted($candidate)) {
            if ([string]::IsNullOrWhiteSpace($BasePath) -or -not (Test-Path -LiteralPath $BasePath)) { return $null }
            $candidate = Join-Path $BasePath $candidate
        }
        return [IO.Path]::GetFullPath($candidate)
    } catch {
        return $candidate
    }
}

function Join-ArgumentList {
    param([string[]]$Arguments)
    $parts = @()
    foreach ($a in @($Arguments)) {
        if ($null -eq $a) { continue }
        $s = [string]$a
        if ($s -match '[\s"]') {
            $s = '"' + ($s -replace '"','\"') + '"'
        }
        $parts += $s
    }
    return ($parts -join ' ')
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runId = ([guid]::NewGuid().ToString('N').Substring(0,8)).ToUpperInvariant()
$scriptPathForRoot = $PSCommandPath
if ([string]::IsNullOrWhiteSpace($scriptPathForRoot)) { $scriptPathForRoot = $MyInvocation.MyCommand.Path }
$scriptRootCandidate = $null
if (-not [string]::IsNullOrWhiteSpace($scriptPathForRoot)) {
    try { $scriptRootCandidate = [IO.Path]::GetFullPath((Split-Path -Parent $scriptPathForRoot)) } catch { $scriptRootCandidate = Split-Path -Parent $scriptPathForRoot }
}
$envRootCandidate = $env:NLD_HOME
$toolRoot = $null
if (-not [string]::IsNullOrWhiteSpace($envRootCandidate) -and (Test-Path -LiteralPath $envRootCandidate)) {
    $envMain = Join-Path $envRootCandidate 'NetLossDoctor.ps1'
    if (Test-Path -LiteralPath $envMain) {
        try { $toolRoot = [IO.Path]::GetFullPath($envRootCandidate) } catch { $toolRoot = $envRootCandidate }
        $Script:ToolRootResolutionNote = 'NLD_HOME_validated_against_NetLossDoctor.ps1'
    } else {
        $Script:ToolRootResolutionNote = 'stale_NLD_HOME_ignored_missing_NetLossDoctor.ps1'
    }
}
if ([string]::IsNullOrWhiteSpace($toolRoot) -and -not [string]::IsNullOrWhiteSpace($scriptRootCandidate) -and (Test-Path -LiteralPath $scriptRootCandidate)) {
    $toolRoot = $scriptRootCandidate
    if ($Script:ToolRootResolutionNote -eq 'not_resolved') { $Script:ToolRootResolutionNote = 'script_location' }
}
if ([string]::IsNullOrWhiteSpace($toolRoot) -or -not (Test-Path -LiteralPath $toolRoot)) {
    Write-Error 'Unable to resolve the NetLossDoctor project root from NLD_HOME or the script location. No report directory was created.'
    exit 24
}
$Script:ToolRoot = $toolRoot
$Script:ReportsRootInputRaw = $ReportsRoot
$Script:ReportsRootResolutionNote = 'default_project_local'
if (-not [string]::IsNullOrWhiteSpace($ReportsRoot)) {
    $resolvedReportsRoot = Resolve-NldFolderPath -Path $ReportsRoot -BasePath $toolRoot
    if ([string]::IsNullOrWhiteSpace($resolvedReportsRoot)) {
        $baseDir = Join-Path (Join-Path $toolRoot 'exports') 'NetLossDoctor_Reports'
        $Script:ReportsRootResolutionNote = 'custom_reports_root_blank_after_expansion; fell_back_to_project_local'
    } else {
        $baseDir = $resolvedReportsRoot
        $Script:ReportsRootResolutionNote = 'custom_reports_root_resolved; relative_inputs_are_rebased_from_tool_root'
    }
} else {
    $baseDir = Join-Path (Join-Path $toolRoot 'exports') 'NetLossDoctor_Reports'
}
try {
    New-DirectorySafe $baseDir
} catch {
    Write-Error ("Unable to create the selected report root '{0}'. No Desktop or OS-temp fallback will be used. {1}" -f $baseDir, $_.Exception.Message)
    exit 25
}

$labelSafe = New-SafeFileName $Label
if ([string]::IsNullOrWhiteSpace($Label)) { $labelSafe = '' }
$labelPart = ''
if (-not [string]::IsNullOrWhiteSpace($labelSafe)) { $labelPart = '_' + $labelSafe }
$runName = 'NetLossDoctor_{0}_{1}_{2}{3}' -f $stamp, $runId, $Mode, $labelPart
$runDir = Join-Path $baseDir $runName
$rawDir = Join-Path $runDir 'raw_logs'
$modemDir = Join-Path $runDir 'modem_pages'
$jsonDir = Join-Path $runDir 'json'
$pktmonDir = Join-Path $runDir 'pktmon'
$loadDir = Join-Path $runDir 'load_test'
$netshTraceDir = Join-Path $runDir 'netsh_trace'
New-DirectorySafe $runDir
New-DirectorySafe $rawDir
New-DirectorySafe $modemDir
New-DirectorySafe $jsonDir
New-DirectorySafe $pktmonDir
New-DirectorySafe $loadDir
New-DirectorySafe $netshTraceDir

$reportPath = Join-Path $runDir 'REPORT.txt'
$summaryPath = Join-Path $runDir 'SUMMARY_REDACTED.txt'
$redactedSummaryPath = Join-Path $runDir 'SUMMARY_REDACTED_PUBLIC_SAFE.txt'
$csvPath = Join-Path $runDir 'packet_loss_tests.csv'
$samplesCsvPath = Join-Path $runDir 'packet_loss_samples.csv'
$suggestionsPath = Join-Path $runDir 'SUGGESTED_FIXES.txt'
$pathPortabilityPath = Join-Path $runDir 'PATH_PORTABILITY_CHECK.txt'
$privacyPath = Join-Path $runDir 'PRIVACY_NOTICE.txt'
$strategyPath = Join-Path $runDir 'DIAGNOSTIC_GUIDE.txt'
$signalChecklistPath = Join-Path $runDir 'MODEM_SIGNAL_CHECKLIST.txt'

function Add-Report {
    param([string]$Text = '')
    $Text | Out-File -FilePath $reportPath -Append -Encoding UTF8
}

function Add-Summary {
    param([string]$Text = '')
    $Text | Out-File -FilePath $summaryPath -Append -Encoding UTF8
}

@"
NetLossDoctor privacy note

This diagnostic bundle may include local IP addresses, router/modem IPs, DNS servers, network adapter names, Wi-Fi SSID/channel/signal, nearby Wi-Fi SSIDs if Wi-Fi scanning is available, Windows network and NCSI event messages, packet-loss results, adapter counters, enabled adapter/filter binding names, VPN/virtual-adapter indicators, TCP/offload and DNS-over-HTTPS configuration, optional Pktmon packet-flow/drop counters, optional Pktmon PCAPNG packet captures, optional netsh trace files, and excerpts from modem status pages if a common modem status page is reachable.

It does not intentionally collect passwords, browser history, saved credentials, documents, photos, or cookies. Some modem/router pages and WLAN reports can contain serial numbers, MAC addresses, usernames, SSIDs, or machine identifiers. Review every file before sharing it with a trusted support recipient.

For public posting, use SUMMARY_REDACTED_PUBLIC_SAFE.txt instead of the full ZIP.
"@ | Set-Content -LiteralPath $privacyPath -Encoding UTF8

@"
Network diagnostic guide

Suggested command order:
1. Run -Mode quick for a short active baseline.
2. Run -Mode standard for a normal diagnostic window.
3. Run -Mode observe -DurationSeconds <seconds> while an intermittent symptom is occurring.
4. Run -Mode appcheck when DNS, HTTPS, or application connectivity fails despite clean ping results.
5. Run -Mode full only when a bounded latency-under-load test is appropriate; use -NoLoad to omit the download.
6. Review the compact *_SUPPORT_EXPORT.zip before sharing it with a trusted support recipient.

What to compare:
- Loss to default gateway: points to local LAN/Wi-Fi/Ethernet/router/NIC when bad.
- Gateway clean + multiple external IPs lossy: points toward router WAN side, modem, coax path, splitter/connectors, ISP node/tap/plant, or upstream congestion/noise.
- TCP/HTTPS failures matter more than isolated ICMP-only loss because some routers and internet hops deprioritize ping.
- Pktmon local drops: useful for separating Windows/NIC-side drops from upstream modem/coax/ISP loss.
- Latency-under-load: if latency rises mainly during transfers, investigate queueing, SQM/QoS, and upload/download contention.
- Modem status/event text: look for T3/T4 timeouts, ranging failures, sync loss, rapidly rising uncorrectables, weak SNR/MER, and suspicious upstream/downstream power.

Interpretation cautions:
- ICMP may be deprioritized. Correlate ping with TCP, DNS, gateway, event, and adapter evidence.
- A bounded load-test transfer is diagnostic context, not a certified line-speed measurement.
- Change one physical or configuration variable at a time and retain before/after reports.
- Do not change adapter, firewall, DNS, proxy, or offload settings based solely on one report.
"@ | Set-Content -LiteralPath $strategyPath -Encoding UTF8

@"
Cable modem signal checklist

Manual page to check:
- Common standalone cable modem page: http://192.168.100.1/
- Some Arris gateways: http://192.168.0.1/

Authentication note:
- Follow the device manufacturer's documentation for local administration. Never put a device username, password, recovery code, or session token in a report.

Capture or screenshot:
- Downstream bonded channels: power, SNR/MER, modulation, correctables, uncorrectables.
- Upstream bonded channels: power, channel count, channel type, symbol rate.
- Event log: T3/T4 timeouts, ranging failures, sync loss, OFDM/OFDMA profile errors.

Useful interpretation:
- Downstream power far outside roughly -10 to +10 dBmV is suspicious; many ARRIS docs allow wider legacy ranges such as -15 to +15 dBmV.
- Downstream SNR/MER should usually be strong. ARRIS examples list 30-33 dB or better for QAM256 depending on power level, while newer gateway guidance may expect about 35 dB or better.
- Upstream power depends on DOCSIS generation, channel count, and modulation. High upstream power often indicates the modem is shouting through too much loss; very low power can also be a clue for plant/configuration issues.
- Correctables can happen, but rapidly rising uncorrectables during symptoms are not normal.
- Refresh the modem page two or three times during symptoms and after changing the coax/splitter layout.
"@ | Set-Content -LiteralPath $signalChecklistPath -Encoding UTF8

$preferencesUsedPath = Join-Path $runDir 'RUN_CONFIGURATION.txt'
@"
NetLossDoctor run configuration

Load-test rate limit Mbps: $LoadRateLimitMbps
Load-test bytes requested in full mode: $LoadBytes

Effective input summary:
- Mode: $Mode
- Label: $Label
- Count override: $Count
- DurationSeconds override: $DurationSeconds
- ExtraTargets provided: $(if ([string]::IsNullOrWhiteSpace($ExtraTargets)) { 'no' } else { 'yes_redacted' })
- ReportsRoot provided: $(if ([string]::IsNullOrWhiteSpace($ReportsRoot)) { 'no_default_project_local' } else { 'yes_redacted' })
- ReportsRoot resolution: $Script:ReportsRootResolutionNote
- Tool root resolution: $Script:ToolRootResolutionNote
- NoZip: $([bool]$NoZip)
- EnablePktmon: $([bool]$EnablePktmon)
- NoLoad: $([bool]$NoLoad)
- NetshTrace: $([bool]$NetshTrace)
- ExportFileLimit requested: $ExportFileLimit; enforced range: 10-20
- Inputs are direct PowerShell parameter bindings; defaults apply only when a value was not supplied.

Interpretation rules:
- Treat load-test throughput as context rather than a certified line-speed measurement.
- Correlate loss and latency with gateway, TCP, DNS, adapter, event, and optional capture evidence.
- The compact support export is capped at 20 files by default.
- The diagnostic does not change persistent execution-policy or network settings.
"@ | Set-Content -LiteralPath $preferencesUsedPath -Encoding UTF8

@(
    'NetLossDoctor path portability check - v' + $Script:Version,
    'Project root detected: ' + $(if ([string]::IsNullOrWhiteSpace($toolRoot)) { 'unavailable' } else { 'available' }),
    'Project root source: ' + $Script:ToolRootResolutionNote,
    'ReportsRoot input provided: ' + $(if ([string]::IsNullOrWhiteSpace($ReportsRoot)) { 'no' } else { 'yes_redacted' }),
    'ReportsRoot resolution note: ' + $Script:ReportsRootResolutionNote,
    'Reports folder created: ' + $(if (Test-Path -LiteralPath $baseDir) { 'yes' } else { 'no' }),
    'Relative report paths are resolved from the validated tool folder, not from the current working directory.',
    'No hardcoded username or drive letter is required for default operation.'
) | Set-Content -LiteralPath $pathPortabilityPath -Encoding UTF8

function Invoke-LoggedCommand {
    param(
        [string]$Name,
        [string]$Command,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 90,
        [string]$OutputDir = $rawDir
    )
    New-DirectorySafe $OutputDir
    $file = Join-Path $OutputDir ((New-SafeFileName $Name) + '.txt')
    $argLine = Join-ArgumentList -Arguments $Arguments
    $header = @()
    $header += 'Name: ' + $Name
    $header += 'Command: ' + $Command + ' ' + $argLine
    $header += 'Started: ' + (Get-Date).ToString('o')
    $header += 'TimeoutSec: ' + $TimeoutSec
    $header += ''
    $output = ''
    $exitCode = $null
    $timedOut = $false
    try {
        $cmdInfo = Get-Command $Command -ErrorAction SilentlyContinue
        if (-not $cmdInfo) {
            $output = 'Command not found: ' + $Command
            $exitCode = -999
        } else {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $cmdInfo.Source
            $psi.Arguments = $argLine
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $psi
            [void]$p.Start()
            # Drain redirected streams asynchronously before waiting. Waiting first can deadlock
            # when a verbose Windows command fills an OS pipe buffer.
            $stdoutTask = $p.StandardOutput.ReadToEndAsync()
            $stderrTask = $p.StandardError.ReadToEndAsync()
            $finished = $p.WaitForExit([Math]::Max(1,$TimeoutSec) * 1000)
            if (-not $finished) {
                $timedOut = $true
                try { $p.Kill() } catch {}
                try { [void]$p.WaitForExit(5000) } catch {}
            } else {
                try { $p.WaitForExit() } catch {}
            }
            try { $stdout = $stdoutTask.GetAwaiter().GetResult() } catch { $stdout = '' }
            try { $stderr = $stderrTask.GetAwaiter().GetResult() } catch { $stderr = '' }
            try { $exitCode = $p.ExitCode } catch { $exitCode = $null }
            $output = $stdout
            if (-not [string]::IsNullOrWhiteSpace($stderr)) { $output += "`r`nSTDERR:`r`n" + $stderr }
        }
    } catch {
        $output = 'ERROR: ' + $_.Exception.Message
        $exitCode = -998
    }
    $footer = @('','ExitCode: ' + $exitCode, 'TimedOut: ' + $timedOut, 'Finished: ' + (Get-Date).ToString('o'))
    ($header + $output + $footer) | Set-Content -LiteralPath $file -Encoding UTF8
    return [PSCustomObject]@{ Name=$Name; File=$file; Output=$output; ExitCode=$exitCode; TimedOut=$timedOut }
}

function Save-TextBlock {
    param(
        [string]$Name,
        [scriptblock]$ScriptBlock,
        [string]$OutputDir = $rawDir
    )
    New-DirectorySafe $OutputDir
    $file = Join-Path $OutputDir ((New-SafeFileName $Name) + '.txt')
    try {
        $result = & $ScriptBlock 2>&1
        $text = $result | Out-String -Width 500
        $text | Set-Content -LiteralPath $file -Encoding UTF8
    } catch {
        ('ERROR: ' + $_.Exception.Message) | Set-Content -LiteralPath $file -Encoding UTF8
    }
    return $file
}

function Save-JsonSafe {
    param(
        [string]$Name,
        [object]$Object,
        [int]$Depth = 6
    )
    $file = Join-Path $jsonDir ((New-SafeFileName $Name) + '.json')
    try {
        $Object | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $file -Encoding UTF8
    } catch {
        $msg = $_.Exception.Message -replace '\\','\\\\' -replace '"','\"'
        ('{"error":"' + $msg + '"}') | Set-Content -LiteralPath $file -Encoding UTF8
    }
    return $file
}

function Test-IsAdmin {
    try {
        $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-ObjectPropertyValue {
    param([object]$Object,[string]$Name)
    try {
        $p = $Object.PSObject.Properties[$Name]
        if ($p) { return $p.Value }
    } catch {}
    return $null
}

function Get-DefaultGatewayInfo {
    $items = @()
    try {
        if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
            $configs = Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address }
            foreach ($c in $configs) {
                $metric = 999999
                try {
                    $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $c.InterfaceIndex -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
                    if ($route -and $route.RouteMetric -ne $null) { $metric = [int]$route.RouteMetric }
                } catch {}
                $dns = @()
                try {
                    if (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue) {
                        $dns = (Get-DnsClientServerAddress -InterfaceIndex $c.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
                    }
                } catch {}
                $items += [PSCustomObject]@{
                    InterfaceAlias = $c.InterfaceAlias
                    InterfaceIndex = $c.InterfaceIndex
                    IPv4Address = (($c.IPv4Address | Select-Object -First 1).IPAddress)
                    Gateway = (($c.IPv4DefaultGateway | Select-Object -First 1).NextHop)
                    DnsServers = ($dns -join ', ')
                    RouteMetric = $metric
                }
            }
        }
    } catch {}
    return $items
}

function Get-DnsServersSafe {
    $servers = @()
    try {
        if (Get-Command Get-DnsClientServerAddress -ErrorAction SilentlyContinue) {
            $servers = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.ServerAddresses } |
                ForEach-Object { $_.ServerAddresses } |
                Where-Object { $_ -and ($_ -notmatch '^0\.0\.0\.0$') } |
                Select-Object -Unique
        }
    } catch {}
    return @($servers)
}

function Get-WifiSignalInfo {
    $info = [PSCustomObject]@{
        IsWifi = $false
        SignalPercent = $null
        RSSIDbm = $null
        RadioType = $null
        Channel = $null
        SSID = $null
        BSSID = $null
        RawFile = $null
    }
    try {
        $file = Join-Path $rawDir 'netsh_wlan_show_interfaces.txt'
        if (Test-Path -LiteralPath $file) {
            $text = Get-Content -LiteralPath $file -Raw -ErrorAction SilentlyContinue
        } else {
            $r = Invoke-LoggedCommand -Name 'netsh_wlan_show_interfaces' -Command 'netsh.exe' -Arguments @('wlan','show','interfaces') -TimeoutSec 30
            $text = $r.Output
        }
        $info.RawFile = $file
        if ($text -match '(?im)^\s*State\s*:\s*connected') { $info.IsWifi = $true }
        if ($text -match '(?im)^\s*Signal\s*:\s*(\d+)\s*%') { $info.SignalPercent = [int]$matches[1]; $info.IsWifi = $true }
        if ($text -match '(?im)^\s*RSSI\s*:\s*(-?\d+)\s*dBm') { $info.RSSIDbm = [int]$matches[1]; $info.IsWifi = $true }
        if ($text -match '(?im)^\s*Radio type\s*:\s*(.+)$') { $info.RadioType = $matches[1].Trim() }
        if ($text -match '(?im)^\s*Channel\s*:\s*(.+)$') { $info.Channel = $matches[1].Trim() }
        if ($text -match '(?im)^\s*SSID\s*:\s*(.+)$') { $info.SSID = $matches[1].Trim() }
        if ($text -match '(?im)^\s*BSSID\s*:\s*(.+)$') { $info.BSSID = $matches[1].Trim() }
    } catch {}
    return $info
}

function Get-Percentile {
    param([double[]]$Values,[double]$Percentile)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 1) { return [math]::Round([double]$sorted[0],2) }
    $rank = [math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    if ($rank -lt 0) { $rank = 0 }
    if ($rank -ge $sorted.Count) { $rank = $sorted.Count - 1 }
    return [math]::Round([double]$sorted[$rank],2)
}

function Get-PingSamplesFromOutput {
    param(
        [string]$Label,
        [string]$Target,
        [string]$Output,
        [datetime]$StartTime
    )
    $samples = @()
    $idx = 0
    $lines = $Output -split "`r?`n"
    foreach ($line in $lines) {
        $trim = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trim)) { continue }
        $status = $null
        $lat = $null
        if ($trim -match '(?i)^Reply from .+?time\s*([=<])\s*([0-9]+)\s*ms') {
            $status = 'Reply'
            $lat = [double]$matches[2]
            if ($matches[1] -eq '<') { $lat = 0.5 }
        } elseif ($trim -match '(?i)Request timed out') { $status = 'Timeout' }
        elseif ($trim -match '(?i)Destination host unreachable') { $status = 'Unreachable' }
        elseif ($trim -match '(?i)General failure') { $status = 'GeneralFailure' }
        elseif ($trim -match '(?i)TTL expired') { $status = 'TTLExpired' }
        if ($status) {
            $idx++
            $samples += [PSCustomObject]@{
                Label = $Label
                Target = $Target
                SampleIndex = $idx
                ApproxTime = ($StartTime.AddSeconds([Math]::Max(0,$idx-1))).ToString('o')
                Status = $status
                LatencyMs = $lat
                RawLine = $trim
            }
        }
    }
    return @($samples)
}

function Parse-PingOutput {
    param(
        [string]$Label,
        [string]$Target,
        [string]$Output,
        [int]$ExpectedCount,
        [string]$File,
        [bool]$TimedOut = $false,
        [datetime]$StartTime = (Get-Date)
    )
    $notes = @()
    if ($TimedOut) { $notes += 'ping job timed out' }
    if ($Output -match '(?i)could not find host|Ping request could not find host') { $notes += 'name lookup failed' }
    if ($Output -match '(?i)Destination host unreachable') { $notes += 'destination host unreachable' }
    if ($Output -match '(?i)General failure') { $notes += 'general network failure' }
    if ($Output -match '(?i)Request timed out') { $notes += 'request timed out' }
    if ($Output -match '(?i)TTL expired') { $notes += 'TTL expired' }

    $samples = @(Get-PingSamplesFromOutput -Label $Label -Target $Target -Output $Output -StartTime $StartTime)
    $times = @($samples | Where-Object { $_.Status -eq 'Reply' -and $_.LatencyMs -ne $null } | ForEach-Object { [double]$_.LatencyMs })

    $sent = $ExpectedCount
    $received = $times.Count
    $summaryMatch = [regex]::Match($Output, '(?i)Sent\s*=\s*(\d+)\s*,\s*Received\s*=\s*(\d+)\s*,\s*Lost\s*=\s*(\d+)')
    if ($summaryMatch.Success) {
        $sent = [int]$summaryMatch.Groups[1].Value
        $receivedFromSummary = [int]$summaryMatch.Groups[2].Value
        if ($Output -notmatch '(?i)Destination host unreachable|General failure|TTL expired') { $received = $receivedFromSummary }
    }
    if ($sent -lt 1) { $sent = $ExpectedCount }
    $lost = $sent - $received
    if ($lost -lt 0) { $lost = 0 }
    $lossPct = [math]::Round((100.0 * $lost / [math]::Max(1,$sent)), 2)

    $min = $null; $avg = $null; $max = $null; $spread = $null; $jitter = $null; $p95 = $null; $p99 = $null
    if ($times.Count -gt 0) {
        $measure = $times | Measure-Object -Minimum -Maximum -Average
        $min = [math]::Round([double]$measure.Minimum, 2)
        $avg = [math]::Round([double]$measure.Average, 2)
        $max = [math]::Round([double]$measure.Maximum, 2)
        $spread = [math]::Round(($max - $min), 2)
        $p95 = Get-Percentile -Values $times -Percentile 95
        $p99 = Get-Percentile -Values $times -Percentile 99
        $sumSq = 0.0
        foreach ($t in $times) { $sumSq += [math]::Pow(($t - $avg), 2) }
        $jitter = [math]::Round([math]::Sqrt($sumSq / [math]::Max(1,$times.Count)), 2)
    }

    $maxLossBurst = 0
    $currentBurst = 0
    foreach ($s in $samples) {
        if ($s.Status -eq 'Reply') { $currentBurst = 0 } else { $currentBurst++; if ($currentBurst -gt $maxLossBurst) { $maxLossBurst = $currentBurst } }
    }

    return [PSCustomObject]@{
        Label = $Label
        Target = $Target
        Sent = $sent
        Received = $received
        Lost = $lost
        LossPct = $lossPct
        MinMs = $min
        AvgMs = $avg
        MaxMs = $max
        P95Ms = $p95
        P99Ms = $p99
        LatencySpreadMs = $spread
        JitterMs = $jitter
        MaxConsecutiveLoss = $maxLossBurst
        Notes = (($notes | Select-Object -Unique) -join '; ')
        RawLog = $File
    }
}

function Start-PingJobSafe {
    param(
        [string]$Label,
        [string]$Target,
        [int]$PingCount,
        [int]$TimeoutMs
    )
    $safe = New-SafeFileName ($Label + '_' + $Target)
    $file = Join-Path $rawDir ('ping_' + $safe + '.txt')
    try {
        return Start-Job -Name ('ping_' + $safe) -ScriptBlock {
            param($Label,$Target,$PingCount,$TimeoutMs,$File)
            $started = Get-Date
            $cmdLine = 'ping.exe -n {0} -w {1} {2}' -f $PingCount, $TimeoutMs, $Target
            $output = & ping.exe -n $PingCount -w $TimeoutMs $Target 2>&1
            $header = @()
            $header += 'Label: ' + $Label
            $header += 'Target: ' + $Target
            $header += 'Started: ' + $started.ToString('o')
            $header += 'Command: ' + $cmdLine
            $header += ''
            ($header + $output) | Set-Content -LiteralPath $File -Encoding UTF8
            [PSCustomObject]@{ Label=$Label; Target=$Target; File=$File; Output=($output -join "`n"); StartTime=$started.ToString('o'); DirectPingData=$false }
        } -ArgumentList $Label,$Target,$PingCount,$TimeoutMs,$file
    } catch {
        $started = Get-Date
        $out = & ping.exe -n $PingCount -w $TimeoutMs $Target 2>&1
        @('Label: ' + $Label, 'Target: ' + $Target, 'Command: ping.exe -n ' + $PingCount + ' -w ' + $TimeoutMs + ' ' + $Target, '') + $out | Set-Content -LiteralPath $file -Encoding UTF8
        return [PSCustomObject]@{ Label=$Label; Target=$Target; File=$file; Output=($out -join "`n"); StartTime=$started.ToString('o'); DirectPingData=$true }
    }
}

function Get-AdapterStatsSnapshot {
    param([string]$Name)
    $items = @()
    try {
        if (Get-Command Get-NetAdapterStatistics -ErrorAction SilentlyContinue) {
            $stats = @(Get-NetAdapterStatistics -ErrorAction SilentlyContinue)
            foreach ($s in $stats) {
                $items += [PSCustomObject]@{
                    Snapshot = $Name
                    Name = (Get-ObjectPropertyValue $s 'Name')
                    InterfaceDescription = (Get-ObjectPropertyValue $s 'InterfaceDescription')
                    ReceivedBytes = (Get-ObjectPropertyValue $s 'ReceivedBytes')
                    SentBytes = (Get-ObjectPropertyValue $s 'SentBytes')
                    ReceivedUnicastPackets = (Get-ObjectPropertyValue $s 'ReceivedUnicastPackets')
                    SentUnicastPackets = (Get-ObjectPropertyValue $s 'SentUnicastPackets')
                    ReceivedMulticastPackets = (Get-ObjectPropertyValue $s 'ReceivedMulticastPackets')
                    SentMulticastPackets = (Get-ObjectPropertyValue $s 'SentMulticastPackets')
                    ReceivedBroadcastPackets = (Get-ObjectPropertyValue $s 'ReceivedBroadcastPackets')
                    SentBroadcastPackets = (Get-ObjectPropertyValue $s 'SentBroadcastPackets')
                    ReceivedDiscardedPackets = (Get-ObjectPropertyValue $s 'ReceivedDiscardedPackets')
                    OutboundDiscardedPackets = (Get-ObjectPropertyValue $s 'OutboundDiscardedPackets')
                    ReceivedPacketErrors = (Get-ObjectPropertyValue $s 'ReceivedPacketErrors')
                    OutboundPacketErrors = (Get-ObjectPropertyValue $s 'OutboundPacketErrors')
                }
            }
        }
    } catch {}
    return @($items)
}

function Compare-AdapterStats {
    param([object[]]$Before,[object[]]$After)
    $fields = @('ReceivedBytes','SentBytes','ReceivedUnicastPackets','SentUnicastPackets','ReceivedDiscardedPackets','OutboundDiscardedPackets','ReceivedPacketErrors','OutboundPacketErrors')
    $deltas = @()
    foreach ($a in @($After)) {
        $b = @($Before | Where-Object { $_.Name -eq $a.Name -and $_.InterfaceDescription -eq $a.InterfaceDescription } | Select-Object -First 1)
        if (-not $b) { continue }
        $obj = [ordered]@{ Name=$a.Name; InterfaceDescription=$a.InterfaceDescription }
        foreach ($f in $fields) {
            $av = $a.$f; $bv = $b.$f
            if ($av -ne $null -and $bv -ne $null) {
                try { $obj[$f + '_Delta'] = ([double]$av - [double]$bv) } catch { $obj[$f + '_Delta'] = $null }
            } else { $obj[$f + '_Delta'] = $null }
        }
        $deltas += [PSCustomObject]$obj
    }
    return @($deltas)
}

function Start-PktmonSession {
    param([bool]$IsAdmin,[string]$ModeName,[switch]$Skip)
    $state = [PSCustomObject]@{ Attempted=$false; Started=$false; Mode=$ModeName; Directory=$pktmonDir; EtlFile=$null; FilterNames=@(); Notes=@(); Files=@() }
    if ($Skip) { $state.Notes += 'Skipped by the safe default. Use -EnablePktmon explicitly to opt in.'; return $state }
    if ($ModeName -eq 'quick') { $state.Notes += 'Skipped in quick mode.'; return $state }
    if (-not $IsAdmin) { $state.Notes += 'Skipped because the tool is not running as administrator.'; return $state }
    if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) { $state.Notes += 'pktmon.exe not found on this Windows version.'; return $state }
    $state.Attempted = $true
    $status = Invoke-LoggedCommand -Name 'pktmon_status_before' -Command 'pktmon.exe' -Arguments @('status') -TimeoutSec 30 -OutputDir $pktmonDir
    $state.Files += $status.File
    if ($status.Output -match '(?i)running|started|capture') {
        if ($status.Output -notmatch '(?i)not\s+(running|started)|stopped') {
            $state.Notes += 'Pktmon already appears to be running; skipped to avoid disrupting an existing capture.'
            return $state
        }
    }
    $filterList = Invoke-LoggedCommand -Name 'pktmon_filter_list_before' -Command 'pktmon.exe' -Arguments @('filter','list') -TimeoutSec 30 -OutputDir $pktmonDir
    $state.Files += $filterList.File
    if ($filterList.ExitCode -ne 0 -or $filterList.Output -notmatch '(?i)\bno\s+filters?\b|filter\s+list\s+is\s+empty') {
        $state.Notes += 'Skipped because existing or unreadable Pktmon filters were detected; the diagnostic never removes another workflow''s filters.'
        return $state
    }
    try {
        foreach ($definition in @(
            [PSCustomObject]@{ Name='NetLossDoctor-ICMP'; Arguments=@('-t','icmp') },
            [PSCustomObject]@{ Name='NetLossDoctor-DNS'; Arguments=@('-p','53') }
        )) {
            $add = Invoke-LoggedCommand -Name ('pktmon_filter_add_' + $definition.Name) -Command 'pktmon.exe' -Arguments (@('filter','add',$definition.Name) + $definition.Arguments) -TimeoutSec 30 -OutputDir $pktmonDir
            $state.Files += $add.File
            if ($add.ExitCode -ne 0) { throw ('Could not add the named Pktmon filter ' + $definition.Name + '.') }
            $state.FilterNames += $definition.Name
        }
        $reset = Invoke-LoggedCommand -Name 'pktmon_reset_counters' -Command 'pktmon.exe' -Arguments @('reset','-counters') -TimeoutSec 30 -OutputDir $pktmonDir
        $state.Files += $reset.File
        if ($ModeName -eq 'full' -or $ModeName -eq 'observe') {
            $etl = Join-Path $pktmonDir 'pktmon_capture.etl'
            $state.EtlFile = $etl
            $args = @('start','--capture','--comp','nics','--pkt-size','128','--file-name',$etl,'--file-size','64')
        } else {
            $args = @('start','--capture','--counters-only','--comp','nics')
        }
        $start = Invoke-LoggedCommand -Name 'pktmon_start' -Command 'pktmon.exe' -Arguments $args -TimeoutSec 30 -OutputDir $pktmonDir
        $state.Files += $start.File
        if ($start.ExitCode -ne 0 -and $start.Output -notmatch '(?i)started|running|capture') { throw 'Pktmon start did not report success.' }
        $state.Started = $true
        $state.Notes += 'Pktmon started with two uniquely named diagnostic filters.'
    } catch {
        $state.Notes += ('Pktmon setup failed safely: ' + $_.Exception.Message)
        try { Invoke-LoggedCommand -Name 'pktmon_setup_cleanup_stop' -Command 'pktmon.exe' -Arguments @('stop') -TimeoutSec 30 -OutputDir $pktmonDir | Out-Null } catch {}
        foreach ($filterName in @($state.FilterNames)) {
            try { Invoke-LoggedCommand -Name ('pktmon_setup_cleanup_' + $filterName) -Command 'pktmon.exe' -Arguments @('filter','remove',$filterName) -TimeoutSec 30 -OutputDir $pktmonDir | Out-Null } catch {}
        }
        $state.Started = $false
        $state.FilterNames = @()
    }
    return $state
}

function Stop-PktmonSession {
    param([object]$State)
    if (-not $State) { return $State }
    try {
        if ($State.Started) {
            foreach ($counterSpec in @(
                [PSCustomObject]@{ Name='pktmon_counters_all'; Arguments=@('counters','--include-hidden','--drop-reason') },
                [PSCustomObject]@{ Name='pktmon_counters_json'; Arguments=@('counters','--json') },
                [PSCustomObject]@{ Name='pktmon_counters_drops'; Arguments=@('counters','--type','drop','--include-hidden','--drop-reason') }
            )) {
                $counter = Invoke-LoggedCommand -Name $counterSpec.Name -Command 'pktmon.exe' -Arguments $counterSpec.Arguments -TimeoutSec 60 -OutputDir $pktmonDir
                $State.Files += $counter.File
            }
            $stop = Invoke-LoggedCommand -Name 'pktmon_stop' -Command 'pktmon.exe' -Arguments @('stop') -TimeoutSec 60 -OutputDir $pktmonDir
            $State.Files += $stop.File
            if ($stop.TimedOut -or $stop.ExitCode -ne 0) {
                throw ('Pktmon stop was not confirmed (exit={0}; timed_out={1}).' -f $stop.ExitCode,[bool]$stop.TimedOut)
            }
            $State.Started = $false
            if ($State.EtlFile -and (Test-Path -LiteralPath $State.EtlFile)) {
                $txt = Join-Path $pktmonDir 'pktmon_capture_brief.txt'
                $stats = Join-Path $pktmonDir 'pktmon_capture_stats.txt'
                $pcap = Join-Path $pktmonDir 'pktmon_capture.pcapng'
                $dropPcap = Join-Path $pktmonDir 'pktmon_drops_only.pcapng'
                foreach ($conversion in @(
                    [PSCustomObject]@{ Name='pktmon_etl2txt_brief'; Arguments=@('etl2txt',$State.EtlFile,'--out',$txt,'--brief'); Output=$txt },
                    [PSCustomObject]@{ Name='pktmon_etl2txt_stats_only'; Arguments=@('etl2txt',$State.EtlFile,'--out',$stats,'--stats-only'); Output=$stats },
                    [PSCustomObject]@{ Name='pktmon_etl2pcap_all'; Arguments=@('etl2pcap',$State.EtlFile,'--out',$pcap); Output=$pcap },
                    [PSCustomObject]@{ Name='pktmon_etl2pcap_drops_only'; Arguments=@('etl2pcap',$State.EtlFile,'--drop-only','--out',$dropPcap); Output=$dropPcap }
                )) {
                    $result = Invoke-LoggedCommand -Name $conversion.Name -Command 'pktmon.exe' -Arguments $conversion.Arguments -TimeoutSec 180 -OutputDir $pktmonDir
                    $State.Files += $result.File
                    if (Test-Path -LiteralPath $conversion.Output) { $State.Files += $conversion.Output }
                }
            }
            $State.Notes += 'Pktmon stopped and counters were exported.'
        }
    } catch {
        $State.Notes += ('Pktmon collection cleanup warning: ' + $_.Exception.Message)
    } finally {
        if ($State.Started) {
            try {
                $fallbackStop = Invoke-LoggedCommand -Name 'pktmon_finally_stop' -Command 'pktmon.exe' -Arguments @('stop') -TimeoutSec 30 -OutputDir $pktmonDir
                $State.Files += $fallbackStop.File
                if (-not $fallbackStop.TimedOut -and $fallbackStop.ExitCode -eq 0) {
                    $State.Started = $false
                    $State.Notes += 'Pktmon stop was confirmed by the cleanup retry.'
                } else {
                    $State.Notes += ('Pktmon cleanup retry did not confirm stop (exit={0}; timed_out={1}); capture state remains marked active.' -f $fallbackStop.ExitCode,[bool]$fallbackStop.TimedOut)
                }
            } catch {
                $State.Notes += ('Pktmon cleanup retry raised an error; capture state remains marked active: ' + $_.Exception.Message)
            }
        }
        $remainingFilters = New-Object System.Collections.Generic.List[string]
        foreach ($filterName in @($State.FilterNames)) {
            try {
                $filterRemove = Invoke-LoggedCommand -Name ('pktmon_filter_remove_' + $filterName) -Command 'pktmon.exe' -Arguments @('filter','remove',$filterName) -TimeoutSec 30 -OutputDir $pktmonDir
                $State.Files += $filterRemove.File
                if ($filterRemove.TimedOut -or $filterRemove.ExitCode -ne 0) { [void]$remainingFilters.Add($filterName) }
            } catch { [void]$remainingFilters.Add($filterName) }
        }
        $State.FilterNames = @($remainingFilters.ToArray())
        if ($State.FilterNames.Count -eq 0) { $State.Notes += 'Named diagnostic Pktmon filters were removed.' }
        else { $State.Notes += ('Could not confirm removal of named Pktmon filter(s): ' + ($State.FilterNames -join ', ')) }
    }
    return $State
}

function Invoke-MtuTests {
    $results = @()
    foreach ($size in @(1472,1464,1400,1200)) {
        $r = Invoke-LoggedCommand -Name ('mtu_df_ping_1.1.1.1_size_' + $size) -Command 'ping.exe' -Arguments @('-4','-f','-n','2','-w','1000','-l',([string]$size),'1.1.1.1') -TimeoutSec 20
        $out = $r.Output
        $results += [PSCustomObject]@{
            Target = '1.1.1.1'
            PayloadBytes = $size
            ApproxEthernetMTU = $size + 28
            Success = [bool]($out -match '(?i)Reply from')
            FragmentationMessage = [bool]($out -match '(?i)fragment|Packet needs to be fragmented')
            TimeoutOrFailure = [bool]($out -match '(?i)timed out|General failure|unreachable')
            RawLog = $r.File
        }
    }
    return @($results)
}

function Invoke-LatencyUnderLoadTest {
    param(
        [string]$Target='1.1.1.1',
        [int]$Bytes=25000000,
        [switch]$Skip,
        [double]$RateLimitMbps=0
    )
    $state = [PSCustomObject]@{
        Attempted=$false; Completed=$false; Skipped=$false; Notes=@(); BytesRequested=$Bytes
        DownloadMbps=$null; PingResult=$null; BaselineAvgMs=$null; LoadedP95Ms=$null; LoadedP99Ms=$null
        LatencyIncreaseMs=$null; Files=@(); LoadRateLimitMbps=$RateLimitMbps
        LoadMethod=''; ThroughputIsLineSpeed=$false
    }
    if ($Skip) { $state.Skipped=$true; $state.Notes += 'Skipped because -NoLoad was used.'; return $state }
    if ($Mode -ne 'full') { $state.Skipped=$true; $state.Notes += 'Skipped except in full mode.'; return $state }
    if ($Bytes -lt 1000000) { $Bytes = 1000000; $state.BytesRequested = $Bytes }
    $state.Attempted=$true
    $state.Notes += 'The bounded load transfer is diagnostic context and is not interpreted as a certified line-speed measurement.'
    if ($RateLimitMbps -gt 0) {
        $state.Notes += ('A load-test rate limit of {0} Mbps was requested. When curl.exe is available, the diagnostic uses curl --limit-rate.' -f $RateLimitMbps)
    }
    New-DirectorySafe $loadDir
    $pingFile = Join-Path $loadDir 'latency_under_load_ping.txt'
    $downloadFile = Join-Path $loadDir 'cloudflare_load_download.tmp'
    $downloadLog = Join-Path $loadDir 'cloudflare_load_download.txt'
    $state.Files += $pingFile
    $state.Files += $downloadLog
    try {
        $pingJob = Start-Job -ScriptBlock {
            param($Target,$File)
            $started = Get-Date
            $out = & ping.exe -n 60 -w 1000 $Target 2>&1
            @('Target: ' + $Target, 'Started: ' + $started.ToString('o'), 'Command: ping.exe -n 60 -w 1000 ' + $Target, '') + $out | Set-Content -LiteralPath $File -Encoding UTF8
            [PSCustomObject]@{ Output=($out -join "`n"); StartTime=$started.ToString('o') }
        } -ArgumentList $Target,$pingFile
        Start-Sleep -Seconds 5
        $url = 'https://speed.cloudflare.com/__down?bytes=' + $Bytes + '&nld=' + ([Guid]::NewGuid().ToString('N'))
        $downloadStarted = Get-Date
        $dlJob = Start-Job -ScriptBlock {
            param($Url,$File,$RateLimitMbps)
            $started = Get-Date
            $method = 'Invoke-WebRequest'
            try {
                $curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue
                if ($RateLimitMbps -gt 0 -and $curl) {
                    $bytesPerSecond = [int64][math]::Max(1024, [math]::Round(($RateLimitMbps * 1000000.0) / 8.0))
                    $method = 'curl.exe --limit-rate ' + $bytesPerSecond + ' bytes/sec'
                    $curlOutput = & $curl.Source --location --silent --show-error --output $File --max-time 65 --limit-rate ([string]$bytesPerSecond) $Url 2>&1
                    $exitCode = $LASTEXITCODE
                    if ($exitCode -ne 0) { throw ('curl.exe exit code ' + $exitCode + ': ' + ($curlOutput -join ' ')) }
                } else {
                    if ($RateLimitMbps -gt 0 -and -not $curl) { $method = 'Invoke-WebRequest; requested rate limit could not be enforced because curl.exe was not found' }
                    Invoke-WebRequest -Uri $Url -OutFile $File -UseBasicParsing -TimeoutSec 65 -ErrorAction Stop
                }
                $item = Get-Item -LiteralPath $File -ErrorAction SilentlyContinue
                $bytes = 0
                if ($item) { $bytes = [int64]$item.Length }
                $seconds = ((Get-Date) - $started).TotalSeconds
                $mbps = $null
                if ($seconds -gt 0) { $mbps = [math]::Round(($bytes * 8 / 1000000.0) / $seconds, 2) }
                [PSCustomObject]@{ Success=$true; Bytes=$bytes; Seconds=[math]::Round($seconds,2); Mbps=$mbps; Error=''; Method=$method; Url=$Url }
            } catch {
                [PSCustomObject]@{ Success=$false; Bytes=0; Seconds=[math]::Round(((Get-Date)-$started).TotalSeconds,2); Mbps=$null; Error=$_.Exception.Message; Method=$method; Url=$Url }
            }
        } -ArgumentList $url,$downloadFile,$RateLimitMbps
        $null = Wait-Job -Job $dlJob -Timeout 75
        if ($dlJob.State -ne 'Completed') {
            try { Stop-Job -Job $dlJob -ErrorAction SilentlyContinue } catch {}
            @('Download timed out after 75 seconds.', 'URL: ' + $url, 'Started: ' + $downloadStarted.ToString('o'), 'LoadRateLimitMbps: ' + $RateLimitMbps) | Set-Content -LiteralPath $downloadLog -Encoding UTF8
            $state.Notes += 'Latency-under-load download timed out.'
        } else {
            $dl = Receive-Job -Job $dlJob -ErrorAction SilentlyContinue | Select-Object -First 1
            ($dl | Format-List * | Out-String -Width 240) | Set-Content -LiteralPath $downloadLog -Encoding UTF8
            if ($dl) { $state.LoadMethod = $dl.Method }
            if ($dl -and $dl.Success) {
                $state.DownloadMbps = $dl.Mbps
                $state.Notes += ('Downloaded {0:n0} bytes at about {1} Mbps while pinging {2}. Method: {3}.' -f $dl.Bytes, $dl.Mbps, $Target, $dl.Method)
            } elseif ($dl) { $state.Notes += ('Download failed: ' + $dl.Error + ' Method: ' + $dl.Method) }
        }
        try { Remove-Job -Job $dlJob -Force -ErrorAction SilentlyContinue } catch {}
        $null = Wait-Job -Job $pingJob -Timeout 80
        if ($pingJob.State -ne 'Completed') { try { Stop-Job -Job $pingJob -ErrorAction SilentlyContinue } catch {} }
        $pd = Receive-Job -Job $pingJob -ErrorAction SilentlyContinue | Select-Object -First 1
        try { Remove-Job -Job $pingJob -Force -ErrorAction SilentlyContinue } catch {}
        if ($pd) {
            $start = Get-Date
            try { $start = [datetime]::Parse($pd.StartTime) } catch {}
            $pr = Parse-PingOutput -Label 'Latency under load' -Target $Target -Output $pd.Output -ExpectedCount 60 -File $pingFile -TimedOut:($pingJob.State -ne 'Completed') -StartTime $start
            $state.PingResult = $pr
            $samples = @(Get-PingSamplesFromOutput -Label 'Latency under load' -Target $Target -Output $pd.Output -StartTime $start)
            $baseline = @($samples | Where-Object { $_.Status -eq 'Reply' -and $_.SampleIndex -le 5 } | ForEach-Object { [double]$_.LatencyMs })
            $loaded = @($samples | Where-Object { $_.Status -eq 'Reply' -and $_.SampleIndex -gt 5 } | ForEach-Object { [double]$_.LatencyMs })
            if ($baseline.Count -gt 0) { $state.BaselineAvgMs = [math]::Round((($baseline | Measure-Object -Average).Average),2) }
            if ($loaded.Count -gt 0) { $state.LoadedP95Ms = Get-Percentile -Values $loaded -Percentile 95; $state.LoadedP99Ms = Get-Percentile -Values $loaded -Percentile 99 }
            if ($state.BaselineAvgMs -ne $null -and $state.LoadedP95Ms -ne $null) { $state.LatencyIncreaseMs = [math]::Round(($state.LoadedP95Ms - $state.BaselineAvgMs),2) }
            $state.Completed = $true
        }
    } catch {
        $state.Notes += ('Latency-under-load test error: ' + $_.Exception.Message)
    } finally {
        foreach ($backgroundJob in @($dlJob,$pingJob)) {
            if ($backgroundJob) {
                try { if ($backgroundJob.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $backgroundJob -ErrorAction SilentlyContinue } } catch {}
                try { Remove-Job -Job $backgroundJob -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        try { if (Test-Path -LiteralPath $downloadFile) { Remove-Item -LiteralPath $downloadFile -Force -ErrorAction SilentlyContinue } } catch {}
    }
    return $state
}

function Collect-WlanReport {
    param([bool]$IsAdmin,[object]$WifiInfo)
    $state = [PSCustomObject]@{ Attempted=$false; Saved=$false; File=$null; Notes=@() }
    if (-not $WifiInfo -or -not $WifiInfo.IsWifi) { $state.Notes += 'Skipped because active connection did not appear to be Wi-Fi.'; return $state }
    if (-not $IsAdmin) { $state.Notes += 'Skipped because admin is usually required for netsh wlan show wlanreport.'; return $state }
    $state.Attempted = $true
    $r = Invoke-LoggedCommand -Name 'netsh_wlan_show_wlanreport' -Command 'netsh.exe' -Arguments @('wlan','show','wlanreport') -TimeoutSec 60
    $candidates = @()
    if ($r.Output -match '([A-Z]:\\[^\r\n]+wlan-report[^\r\n]+\.html)') { $candidates += $matches[1].Trim() }
    $candidates += (Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.html')
    $candidates += (Join-Path $env:ProgramData 'Microsoft\Windows\WlanReport\wlan-report-latest.cab')
    foreach ($c in $candidates | Select-Object -Unique) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            try {
                $dest = Join-Path $rawDir ('wlan_report_' + (Split-Path $c -Leaf))
                Copy-Item -LiteralPath $c -Destination $dest -Force
                $state.Saved = $true
                $state.File = $dest
                break
            } catch {}
        }
    }
    if (-not $state.Saved) { $state.Notes += 'netsh ran, but the WLAN report file was not found in the expected location.' }
    return $state
}


function Get-FirstHopProbe {
    param([string]$DefaultGateway)
    $state = [PSCustomObject]@{ Attempted=$false; FirstHop=$null; FirstHopNumber=$null; Hops=@(); RawFile=$null; Notes=@() }
    try {
        $state.Attempted = $true
        $r = Invoke-LoggedCommand -Name 'early_tracert_1.1.1.1_h8' -Command 'tracert.exe' -Arguments @('-d','-4','-h','8','1.1.1.1') -TimeoutSec 90
        $state.RawFile = $r.File
        $lines = $r.Output -split "`r?`n"
        foreach ($line in $lines) {
            $m = [regex]::Match($line, '^\s*(\d+)\s+.*?((?:\d{1,3}\.){3}\d{1,3})\s*$')
            if ($m.Success) {
                $hopNo = [int]$m.Groups[1].Value
                $ip = $m.Groups[2].Value
                $state.Hops += [PSCustomObject]@{ Hop=$hopNo; IP=$ip; RawLine=$line.Trim() }
            }
        }
        $candidate = $null
        foreach ($h in @($state.Hops | Sort-Object Hop)) {
            if ($h.Hop -ge 2 -and $h.IP -ne $DefaultGateway) { $candidate = $h; break }
        }
        if ($candidate) {
            $state.FirstHop = $candidate.IP
            $state.FirstHopNumber = $candidate.Hop
            $state.Notes += ('First hop after your router appears to be {0} at traceroute hop {1}. This is often the ISP/CMTS side, but ICMP there may be rate-limited.' -f $candidate.IP,$candidate.Hop)
        } else {
            $state.Notes += 'Could not identify the first hop after the default gateway from the early traceroute.'
        }
    } catch {
        $state.Notes += ('First-hop probe error: ' + $_.Exception.Message)
    }
    return $state
}


function Test-FirstHopEchoProbe {
    param([string]$Target)
    $state = [PSCustomObject]@{
        Target = $Target
        Attempted = $false
        Sent = 0
        Received = 0
        Responsive = $null
        RawFile = $null
        Notes = @()
    }
    if ([string]::IsNullOrWhiteSpace($Target)) {
        $state.Notes += 'No target was supplied.'
        return $state
    }
    try {
        $state.Attempted = $true
        $r = Invoke-LoggedCommand -Name ('first_hop_echo_probe_' + (New-SafeFileName $Target)) -Command 'ping.exe' -Arguments @('-n','3','-w','1000',$Target) -TimeoutSec 8
        $state.RawFile = $r.File
        $out = [string]$r.Output
        $m = [regex]::Match($out, '(?i)Sent\s*=\s*(\d+)\s*,\s*Received\s*=\s*(\d+)')
        if ($m.Success) {
            $state.Sent = [int]$m.Groups[1].Value
            $state.Received = [int]$m.Groups[2].Value
        } else {
            $state.Sent = 3
            $state.Received = @([regex]::Matches($out, '(?im)^Reply\s+from\s+')).Count
        }
        $state.Responsive = [bool]($state.Received -gt 0)
        if ($state.Responsive) {
            $state.Notes += ('First hop {0} responded to ordinary ICMP echo ({1}/{2}). It is useful to include in the longer ping set.' -f $Target,$state.Received,$state.Sent)
        } else {
            $state.Notes += ('First hop {0} did not respond to ordinary ICMP echo in a brief probe. This is common for ISP/CMTS/router hops that still forward traffic normally, so NetLossDoctor will not include it in the long packet-loss target list.' -f $Target)
        }
    } catch {
        $state.Notes += ('First-hop echo probe error: ' + $_.Exception.Message)
    }
    return $state
}

function Invoke-TcpConnectivityTests {
    $tests = @(
        [PSCustomObject]@{ Label='Cloudflare HTTPS'; Host='cloudflare.com'; Port=443 },
        [PSCustomObject]@{ Label='Google HTTPS'; Host='www.google.com'; Port=443 },
        [PSCustomObject]@{ Label='Cloudflare Speed HTTPS'; Host='speed.cloudflare.com'; Port=443 },
        [PSCustomObject]@{ Label='Cloudflare DNS TCP'; Host='1.1.1.1'; Port=53 },
        [PSCustomObject]@{ Label='Google DNS TCP'; Host='8.8.8.8'; Port=53 }
    )
    $results = @()
    foreach ($t in $tests) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $rawFile = Join-Path $rawDir ('tcp_test_' + (New-SafeFileName ($t.Label + '_' + $t.Host + '_' + $t.Port)) + '.txt')
        $obj = [ordered]@{ Label=$t.Label; Host=$t.Host; Port=$t.Port; Attempted=$true; TcpTestSucceeded=$null; PingSucceeded=$null; RemoteAddress=$null; InterfaceAlias=$null; SourceAddress=$null; ElapsedMs=$null; Error=''; RawLog=$rawFile }
        try {
            if (Get-Command Test-NetConnection -ErrorAction SilentlyContinue) {
                $res = Test-NetConnection -ComputerName $t.Host -Port $t.Port -InformationLevel Detailed -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                ($res | Format-List * | Out-String -Width 260) | Set-Content -LiteralPath $rawFile -Encoding UTF8
                $obj.TcpTestSucceeded = [bool]$res.TcpTestSucceeded
                $obj.PingSucceeded = [bool]$res.PingSucceeded
                if ($res.RemoteAddress) { $obj.RemoteAddress = [string]$res.RemoteAddress }
                if ($res.InterfaceAlias) { $obj.InterfaceAlias = [string]$res.InterfaceAlias }
                if ($res.SourceAddress) {
                    try {
                        if ($res.SourceAddress.IPAddress) { $obj.SourceAddress = [string]$res.SourceAddress.IPAddress }
                        else { $obj.SourceAddress = [string]$res.SourceAddress }
                    } catch { $obj.SourceAddress = [string]$res.SourceAddress }
                }
            } else {
                $client = New-Object System.Net.Sockets.TcpClient
                $iar = $client.BeginConnect($t.Host, [int]$t.Port, $null, $null)
                $ok = $iar.AsyncWaitHandle.WaitOne(3000, $false)
                if ($ok) { $client.EndConnect($iar) }
                $obj.TcpTestSucceeded = [bool]$ok
                try { $client.Close() } catch {}
                ('Fallback TcpClient result for {0}:{1}: {2}' -f $t.Host,$t.Port,$ok) | Set-Content -LiteralPath $rawFile -Encoding UTF8
            }
        } catch {
            $obj.Error = $_.Exception.Message
            ('ERROR: ' + $_.Exception.Message) | Set-Content -LiteralPath $rawFile -Encoding UTF8
        } finally {
            $sw.Stop()
            $obj.ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds,1)
        }
        $results += [PSCustomObject]$obj
    }
    return @($results)
}

function Invoke-DnsTimingTests {
    param([string[]]$DnsServers)
    $dnsLookupHosts = @('cloudflare.com','google.com','dns.google')
    $servers = New-Object System.Collections.Generic.List[string]
    $servers.Add('SYSTEM_DEFAULT') | Out-Null
    foreach ($s in @($DnsServers)) {
        if ($s -and ([string]$s) -notmatch ':') { $servers.Add([string]$s) | Out-Null }
    }
    $servers.Add('1.1.1.1') | Out-Null
    $servers.Add('8.8.8.8') | Out-Null
    $results = @()
    foreach ($serverObj in @($servers.ToArray() | Select-Object -Unique)) {
        $server = [string]$serverObj
        foreach ($targetHost in $dnsLookupHosts) {
            $name = 'dns_timing_' + (New-SafeFileName ($server + '_' + $targetHost))
            $nslookupArgs = @($targetHost)
            if ($server -ne 'SYSTEM_DEFAULT') { $nslookupArgs += $server }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $rawFile = Join-Path $rawDir ((New-SafeFileName $name) + '.txt')
            $success = $false
            $timedOut = $false
            $errorHint = ''
            try {
                $r = Invoke-LoggedCommand -Name $name -Command 'nslookup.exe' -Arguments $nslookupArgs -TimeoutSec 20
                $rawFile = $r.File
                $timedOut = [bool]$r.TimedOut
                $out = [string]$r.Output
                if ($out -match '(?im)^Address:\s+(?:\d{1,3}\.){3}\d{1,3}' -and $out -notmatch "(?i)timed out|can.?t find|non-existent|server failed|refused") { $success = $true }
                if (-not $success) {
                    $errorLines = @($out -split "`r?`n" | Where-Object { $_ -match "(?i)timed out|can.?t find|non-existent|server failed|refused|No response" } | Select-Object -First 2)
                    $errorHint = ($errorLines -join ' | ')
                    if ([string]::IsNullOrWhiteSpace($errorHint) -and $timedOut) { $errorHint = 'nslookup command timed out' }
                    if ([string]::IsNullOrWhiteSpace($errorHint) -and -not $success) { $errorHint = 'nslookup did not return a normal IPv4 Address line' }
                }
            } catch {
                $errorHint = $_.Exception.Message
                try { ('ERROR: ' + $errorHint) | Set-Content -LiteralPath $rawFile -Encoding UTF8 } catch {}
            } finally {
                $sw.Stop()
            }
            $results += [PSCustomObject]@{
                Host = $targetHost
                Server = $server
                Success = $success
                ElapsedMs = [math]::Round($sw.Elapsed.TotalMilliseconds,1)
                TimedOut = $timedOut
                ErrorHint = $errorHint
                RawLog = $rawFile
            }
        }
    }
    return @($results)
}

function Get-AdapterDriverAnalysis {
    param([object[]]$GatewayInfo)
    $activeAliases = @()
    try { $activeAliases = @($GatewayInfo | Where-Object { $_.InterfaceAlias } | ForEach-Object { $_.InterfaceAlias } | Select-Object -Unique) } catch {}
    $items = @()
    try {
        if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
            $adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or ($activeAliases -contains $_.Name) })
            foreach ($a in $adapters) {
                $driverInfo = [string]$a.DriverInformation
                $driverDate = $null
                $driverVersion = $null
                if ($driverInfo -match '(?i)Driver\s+Date\s+([0-9]{4}-[0-9]{2}-[0-9]{2})') { try { $driverDate = [datetime]::Parse($matches[1]) } catch {} }
                if ($driverInfo -match '(?i)Version\s+([^\s]+)') { $driverVersion = $matches[1] }
                $ageDays = $null
                if ($driverDate) { $ageDays = [math]::Round(((Get-Date) - $driverDate).TotalDays,0) }
                $items += [PSCustomObject]@{
                    Name = $a.Name
                    InterfaceDescription = $a.InterfaceDescription
                    Status = $a.Status
                    LinkSpeed = [string]$a.LinkSpeed
                    MediaType = [string]$a.MediaType
                    DriverDate = if ($driverDate) { $driverDate.ToString('yyyy-MM-dd') } else { $null }
                    DriverVersion = $driverVersion
                    DriverAgeDays = $ageDays
                    DriverLooksOld = [bool]($ageDays -ne $null -and $ageDays -gt 1095)
                    DriverInformation = $driverInfo
                }
            }
        }
    } catch {}
    return @($items)
}


function Get-NetworkStackHealthSnapshot {
    param(
        [string[]]$DnsServers = @(),
        [object[]]$GatewayInfo = @()
    )
    $notes = New-Object System.Collections.Generic.List[string]
    $cmdletAvailability = [ordered]@{}
    $cmdletNames = @(
        'Get-NetAdapter','Get-NetAdapterBinding','Get-NetAdapterAdvancedProperty',
        'Get-NetOffloadGlobalSetting','Get-NetTCPSetting','Get-NetAdapterRss',
        'Get-NetAdapterRsc','Get-NetAdapterLso','Get-NetAdapterChecksumOffload',
        'Get-NetAdapterUso','Get-DnsClientDohServerAddress','Get-NetConnectionProfile',
        'Get-NetRoute','Get-WinEvent'
    )
    foreach ($cmdletName in $cmdletNames) {
        $cmdletAvailability[$cmdletName] = [bool](Get-Command $cmdletName -ErrorAction Ignore)
    }

    $allAdapters = @()
    $activeAdapters = @()
    $activeNames = @()
    try {
        if ($cmdletAvailability['Get-NetAdapter']) {
            $allAdapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Ignore)
            $activeAdapters = @($allAdapters | Where-Object { [string]$_.Status -eq 'Up' })
            $activeNames = @($activeAdapters | ForEach-Object { [string]$_.Name } | Where-Object { $_ } | Select-Object -Unique)
        }
    } catch { $notes.Add(('Adapter inventory failed: ' + $_.Exception.Message)) | Out-Null }

    $vpnPattern = '(?i)vpn|wireguard|wintun|tap|tun|openvpn|cisco|fortinet|checkpoint|zscaler|tailscale|zerotier|hamachi|vEthernet|hyper-v|vmware|virtualbox|loopback|wan miniport'
    $vpnLikeAdapters = @($activeAdapters | Where-Object { (([string]$_.Name + ' ' + [string]$_.InterfaceDescription) -match $vpnPattern) })
    $activeAdapterSummary = @($activeAdapters | ForEach-Object {
        [PSCustomObject]@{
            Name = [string]$_.Name
            InterfaceDescription = [string]$_.InterfaceDescription
            InterfaceIndex = (Get-ObjectPropertyValue $_ 'InterfaceIndex')
            Status = [string]$_.Status
            LinkSpeed = [string]$_.LinkSpeed
            MediaType = [string]$_.MediaType
            PhysicalMediaType = [string](Get-ObjectPropertyValue $_ 'PhysicalMediaType')
            VpnOrVirtualLike = [bool]((([string]$_.Name + ' ' + [string]$_.InterfaceDescription) -match $vpnPattern))
        }
    })

    $defaultRoutes = @()
    try {
        if ($cmdletAvailability['Get-NetRoute']) {
            $activeIndexes = @($activeAdapters | ForEach-Object { [int](Get-ObjectPropertyValue $_ 'InterfaceIndex') })
            foreach ($prefix in @('0.0.0.0/0','::/0')) {
                $routes = @(Get-NetRoute -DestinationPrefix $prefix -ErrorAction Ignore)
                foreach ($route in $routes) {
                    $ifIndex = [int](Get-ObjectPropertyValue $route 'InterfaceIndex')
                    if ($activeIndexes.Count -gt 0 -and $activeIndexes -notcontains $ifIndex) { continue }
                    $defaultRoutes += [PSCustomObject]@{
                        AddressFamily = [string](Get-ObjectPropertyValue $route 'AddressFamily')
                        DestinationPrefix = [string](Get-ObjectPropertyValue $route 'DestinationPrefix')
                        InterfaceAlias = [string](Get-ObjectPropertyValue $route 'InterfaceAlias')
                        InterfaceIndex = $ifIndex
                        NextHop = [string](Get-ObjectPropertyValue $route 'NextHop')
                        RouteMetric = (Get-ObjectPropertyValue $route 'RouteMetric')
                        Protocol = [string](Get-ObjectPropertyValue $route 'Protocol')
                        State = [string](Get-ObjectPropertyValue $route 'State')
                    }
                }
            }
        }
    } catch { $notes.Add(('Default-route inventory failed: ' + $_.Exception.Message)) | Out-Null }
    $ipv4Routes = @($defaultRoutes | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' })
    $ipv6Routes = @($defaultRoutes | Where-Object { $_.DestinationPrefix -eq '::/0' })

    $allBindings = @()
    $thirdPartyBindings = @()
    try {
        if ($cmdletAvailability['Get-NetAdapterBinding']) {
            foreach ($adapterName in $activeNames) {
                $bindings = @(Get-NetAdapterBinding -Name $adapterName -AllBindings -ErrorAction Ignore)
                foreach ($binding in $bindings) {
                    $record = [PSCustomObject]@{
                        InterfaceAlias = $adapterName
                        DisplayName = [string](Get-ObjectPropertyValue $binding 'DisplayName')
                        ComponentID = [string](Get-ObjectPropertyValue $binding 'ComponentID')
                        Enabled = [bool](Get-ObjectPropertyValue $binding 'Enabled')
                    }
                    $allBindings += $record
                    if ($record.Enabled -and ($record.ComponentID -notmatch '^ms_' -or (($record.DisplayName + ' ' + $record.ComponentID) -match $vpnPattern))) {
                        $thirdPartyBindings += $record
                    }
                }
            }
            Save-TextBlock -Name 'Get-NetAdapterBinding_active' -ScriptBlock {
                foreach ($adapterName in $activeNames) {
                    '=== ' + $adapterName + ' ==='
                    Get-NetAdapterBinding -Name $adapterName -AllBindings -ErrorAction Ignore |
                        Sort-Object DisplayName | Format-Table -AutoSize Name,DisplayName,ComponentID,Enabled
                    ''
                }
            } | Out-Null
        }
    } catch { $notes.Add(('Adapter-binding inventory failed: ' + $_.Exception.Message)) | Out-Null }

    $advancedPropertyCount = 0
    try {
        if ($cmdletAvailability['Get-NetAdapterAdvancedProperty']) {
            Save-TextBlock -Name 'Get-NetAdapterAdvancedProperty_active' -ScriptBlock {
                foreach ($adapterName in $activeNames) {
                    '=== ' + $adapterName + ' ==='
                    Get-NetAdapterAdvancedProperty -Name $adapterName -ErrorAction Ignore |
                        Sort-Object DisplayName | Format-Table -AutoSize Name,DisplayName,DisplayValue,RegistryKeyword
                    ''
                }
            } | Out-Null
            foreach ($adapterName in $activeNames) {
                $advancedPropertyCount += @(Get-NetAdapterAdvancedProperty -Name $adapterName -ErrorAction Ignore).Count
            }
        }
    } catch { $notes.Add(('Adapter advanced-property inventory failed: ' + $_.Exception.Message)) | Out-Null }

    $offloadCounts = [ordered]@{ Global=0; Rss=0; Rsc=0; Lso=0; Checksum=0; Uso=0; TcpSettings=0 }
    try {
        if ($cmdletAvailability['Get-NetOffloadGlobalSetting']) {
            $offloadCounts.Global = @(Get-NetOffloadGlobalSetting -ErrorAction Ignore).Count
            Save-TextBlock -Name 'Get-NetOffloadGlobalSetting' -ScriptBlock { Get-NetOffloadGlobalSetting -ErrorAction Ignore | Format-List * } | Out-Null
        }
        if ($cmdletAvailability['Get-NetTCPSetting']) {
            $offloadCounts.TcpSettings = @(Get-NetTCPSetting -ErrorAction Ignore).Count
            Save-TextBlock -Name 'Get-NetTCPSetting' -ScriptBlock { Get-NetTCPSetting -ErrorAction Ignore | Sort-Object SettingName | Format-List * } | Out-Null
        }
        foreach ($pair in @(
            [PSCustomObject]@{ Cmd='Get-NetAdapterRss'; Key='Rss' },
            [PSCustomObject]@{ Cmd='Get-NetAdapterRsc'; Key='Rsc' },
            [PSCustomObject]@{ Cmd='Get-NetAdapterLso'; Key='Lso' },
            [PSCustomObject]@{ Cmd='Get-NetAdapterChecksumOffload'; Key='Checksum' },
            [PSCustomObject]@{ Cmd='Get-NetAdapterUso'; Key='Uso' }
        )) {
            if (-not $cmdletAvailability[$pair.Cmd]) { continue }
            $cmdName = [string]$pair.Cmd
            $keyName = [string]$pair.Key
            $records = @()
            foreach ($adapterName in $activeNames) {
                try { $records += @(& $cmdName -Name $adapterName -ErrorAction Ignore) } catch {}
            }
            $offloadCounts[$keyName] = $records.Count
            $recordsCopy = @($records)
            Save-TextBlock -Name ($cmdName + '_active') -ScriptBlock { $recordsCopy | Format-List * } | Out-Null
        }
    } catch { $notes.Add(('TCP/offload inventory failed: ' + $_.Exception.Message)) | Out-Null }

    $dohRecords = @()
    try {
        if ($cmdletAvailability['Get-DnsClientDohServerAddress'] -and @($DnsServers).Count -gt 0) {
            $activeDnsForDoh = @($DnsServers | Select-Object -Unique)
            $dohRecords = @(Get-DnsClientDohServerAddress -ServerAddress $activeDnsForDoh -ErrorAction Ignore |
                Select-Object ServerAddress,DohTemplate,AllowFallbackToUdp,AutoUpgrade)
            $dohCopy = @($dohRecords)
            Save-TextBlock -Name 'Get-DnsClientDohServerAddress_active' -ScriptBlock { $dohCopy | Format-Table -AutoSize * } | Out-Null
        }
    } catch { $notes.Add(('DoH configuration inventory failed: ' + $_.Exception.Message)) | Out-Null }

    $profiles = @()
    try {
        if ($cmdletAvailability['Get-NetConnectionProfile']) {
            $profiles = @(Get-NetConnectionProfile -ErrorAction Ignore |
                Select-Object InterfaceAlias,InterfaceIndex,NetworkCategory,DomainAuthenticationKind,IPv4Connectivity,IPv6Connectivity)
        }
    } catch { $notes.Add(('Network profile inventory failed: ' + $_.Exception.Message)) | Out-Null }

    $ncsiEvents = @()
    $ncsiEventError = $null
    try {
        if ($cmdletAvailability['Get-WinEvent']) {
            $ncsiEvents = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-NCSI/Operational'; StartTime=(Get-Date).AddDays(-7)} -MaxEvents 120 -ErrorAction Stop |
                Select-Object TimeCreated,Id,LevelDisplayName,Message)
            if ($ncsiEvents.Count -gt 0) {
                $ncsiEvents | Format-List * | Out-String -Width 500 | Set-Content -LiteralPath (Join-Path $rawDir 'NCSI_Operational_recent.txt') -Encoding UTF8
            } else {
                'No NCSI Operational events were returned for the last 7 days.' | Set-Content -LiteralPath (Join-Path $rawDir 'NCSI_Operational_recent.txt') -Encoding UTF8
            }
        }
    } catch {
        $ncsiEventError = $_.Exception.Message
        ('NCSI Operational log unavailable: ' + $ncsiEventError) | Set-Content -LiteralPath (Join-Path $rawDir 'NCSI_Operational_recent.txt') -Encoding UTF8
    }

    $ncsiDns = [ordered]@{ Attempted=$false; Success=$false; TimedOut=$false; ExitCode=$null; ExpectedAddressSeen=$false; Note='not_attempted' }
    try {
        if (Get-Command nslookup.exe -ErrorAction Ignore) {
            $ncsiDns.Attempted = $true
            $dnsProbe = Invoke-LoggedCommand -Name 'ncsi_dns_probe' -Command 'nslookup.exe' -Arguments @('dns.msftncsi.com') -TimeoutSec 15 -OutputDir $rawDir
            $ncsiDns.TimedOut = [bool]$dnsProbe.TimedOut
            $ncsiDns.ExitCode = $dnsProbe.ExitCode
            $ncsiDns.ExpectedAddressSeen = [bool]([string]$dnsProbe.Output -match '131\.107\.255\.255')
            $ncsiDns.Success = [bool](-not $dnsProbe.TimedOut -and $dnsProbe.ExitCode -eq 0 -and ([string]$dnsProbe.Output -notmatch '(?i)timed out|non-existent|server failed|refused'))
            $ncsiDns.Note = if ($ncsiDns.Success) { 'dns_probe_completed' } else { 'dns_probe_failed_or_timed_out' }
        }
    } catch { $ncsiDns.Note = 'dns_probe_error: ' + $_.Exception.Message }

    $ncsiHttp = [ordered]@{ Attempted=$false; Success=$false; TimedOut=$false; ExitCode=$null; ExpectedContentSeen=$false; Method='not_attempted'; Note='not_attempted' }
    try {
        if (Get-Command curl.exe -ErrorAction Ignore) {
            $ncsiHttp.Attempted = $true
            $ncsiHttp.Method = 'curl.exe'
            $httpProbe = Invoke-LoggedCommand -Name 'ncsi_http_probe' -Command 'curl.exe' -Arguments @('--silent','--show-error','--location','--max-time','12','http://www.msftconnecttest.com/connecttest.txt') -TimeoutSec 18 -OutputDir $rawDir
            $ncsiHttp.TimedOut = [bool]$httpProbe.TimedOut
            $ncsiHttp.ExitCode = $httpProbe.ExitCode
            $ncsiHttp.ExpectedContentSeen = [bool](([string]$httpProbe.Output).Trim() -match '^Microsoft Connect Test')
            $ncsiHttp.Success = [bool](-not $httpProbe.TimedOut -and $httpProbe.ExitCode -eq 0 -and $ncsiHttp.ExpectedContentSeen)
            $ncsiHttp.Note = if ($ncsiHttp.Success) { 'http_probe_expected_content_received' } else { 'http_probe_failed_or_content_mismatch' }
        } else {
            $ncsiHttp.Attempted = $true
            $ncsiHttp.Method = 'Invoke-WebRequest'
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri 'http://www.msftconnecttest.com/connecttest.txt' -TimeoutSec 12 -ErrorAction Stop
                $ncsiHttp.ExitCode = 0
                $ncsiHttp.ExpectedContentSeen = [bool](([string]$response.Content).Trim() -match '^Microsoft Connect Test')
                $ncsiHttp.Success = [bool]$ncsiHttp.ExpectedContentSeen
                $ncsiHttp.Note = if ($ncsiHttp.Success) { 'http_probe_expected_content_received' } else { 'http_probe_content_mismatch' }
                ('Method: Invoke-WebRequest' + [Environment]::NewLine + 'ElapsedMs: ' + [math]::Round($sw.Elapsed.TotalMilliseconds,1) + [Environment]::NewLine + 'ExpectedContentSeen: ' + $ncsiHttp.ExpectedContentSeen) |
                    Set-Content -LiteralPath (Join-Path $rawDir 'ncsi_http_probe.txt') -Encoding UTF8
            } catch {
                $ncsiHttp.Note = 'http_probe_error: ' + $_.Exception.Message
                $ncsiHttp.TimedOut = [bool]($_.Exception.Message -match '(?i)timed out|timeout')
                ('Method: Invoke-WebRequest' + [Environment]::NewLine + 'ERROR: ' + $_.Exception.Message) |
                    Set-Content -LiteralPath (Join-Path $rawDir 'ncsi_http_probe.txt') -Encoding UTF8
            } finally { $sw.Stop() }
        }
    } catch { $ncsiHttp.Note = 'http_probe_error: ' + $_.Exception.Message }

    $proxyState = [ordered]@{ Attempted=$false; ProxyDetected=$null; Note='not_attempted' }
    try {
        if (Get-Command netsh.exe -ErrorAction Ignore) {
            $proxyState.Attempted = $true
            $proxyProbe = Invoke-LoggedCommand -Name 'netsh_winhttp_show_proxy' -Command 'netsh.exe' -Arguments @('winhttp','show','proxy') -TimeoutSec 20 -OutputDir $rawDir
            if ([string]$proxyProbe.Output -match '(?i)Direct access \(no proxy server\)') {
                $proxyState.ProxyDetected = $false
                $proxyState.Note = 'direct_access_no_winhttp_proxy'
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$proxyProbe.Output)) {
                $proxyState.ProxyDetected = $true
                $proxyState.Note = 'winhttp_proxy_or_autoconfig_detected_value_not_exported_in_summary'
            }
        }
    } catch { $proxyState.Note = 'proxy_inventory_error: ' + $_.Exception.Message }

    $tcpGlobal = [ordered]@{ AutoTuningLevel=$null; ReceiveSideScaling=$null; ReceiveSegmentCoalescing=$null; EcnCapability=$null }
    try {
        $tcpGlobalPath = Join-Path $rawDir 'netsh_int_tcp_show_global.txt'
        if (Test-Path -LiteralPath $tcpGlobalPath) {
            $tcpText = Get-Content -LiteralPath $tcpGlobalPath -Raw -ErrorAction Ignore
            foreach ($pair in @(
                [PSCustomObject]@{ Key='AutoTuningLevel'; Pattern='(?im)^\s*Receive Window Auto-Tuning Level\s*:\s*([^\r\n]+)' },
                [PSCustomObject]@{ Key='ReceiveSideScaling'; Pattern='(?im)^\s*Receive-Side Scaling State\s*:\s*([^\r\n]+)' },
                [PSCustomObject]@{ Key='ReceiveSegmentCoalescing'; Pattern='(?im)^\s*Receive Segment Coalescing State\s*:\s*([^\r\n]+)' },
                [PSCustomObject]@{ Key='EcnCapability'; Pattern='(?im)^\s*ECN Capability\s*:\s*([^\r\n]+)' }
            )) {
                $match = [regex]::Match([string]$tcpText,[string]$pair.Pattern)
                if ($match.Success) { $tcpGlobal[$pair.Key] = $match.Groups[1].Value.Trim() }
            }
        }
    } catch { $notes.Add(('TCP global parsing failed: ' + $_.Exception.Message)) | Out-Null }

    $profileInternet = @($profiles | Where-Object { [string]$_.IPv4Connectivity -eq 'Internet' -or [string]$_.IPv6Connectivity -eq 'Internet' }).Count -gt 0
    $ncsiMismatch = $false
    if ($profileInternet -and (-not $ncsiHttp.Success -or -not $ncsiDns.Success)) {
        $ncsiMismatch = $true
        $notes.Add('Windows reports Internet connectivity, but one or more NCSI reference probes failed; proxy/firewall/filter-specific probe handling may be involved.') | Out-Null
    } elseif (-not $profileInternet -and ($ncsiHttp.Success -or $ncsiDns.Success)) {
        $ncsiMismatch = $true
        $notes.Add('NCSI reference probe succeeded while Get-NetConnectionProfile did not report Internet; Windows connectivity-state evaluation may be stale or inconsistent.') | Out-Null
    }
    if ($ipv4Routes.Count -gt 1 -or $ipv6Routes.Count -gt 1) {
        $notes.Add('Multiple active default routes were detected; VPN/virtual adapter route competition can change which path applications use.') | Out-Null
    }
    if ($thirdPartyBindings.Count -gt 0) {
        $notes.Add(('Enabled non-Microsoft or VPN/security-like adapter bindings detected: ' + $thirdPartyBindings.Count + '. Presence is not proof of a fault.')) | Out-Null
    }
    if ($vpnLikeAdapters.Count -gt 0) {
        $notes.Add(('Active VPN/virtual-like adapters detected: ' + $vpnLikeAdapters.Count + '. Test with the intended VPN state documented.')) | Out-Null
    }

    return [PSCustomObject][ordered]@{
        CollectedAt = (Get-Date).ToString('o')
        ResearchReviewDate = $Script:NetworkResearchReviewDate
        ResearchStatus = $Script:NetworkResearchStatus
        CmdletAvailability = $cmdletAvailability
        ActiveAdapterCount = $activeAdapters.Count
        ActivePhysicalAdapterCount = @($activeAdapterSummary | Where-Object { -not $_.VpnOrVirtualLike }).Count
        ActiveAdapters = $activeAdapterSummary
        ActiveVpnOrVirtualAdapterCount = $vpnLikeAdapters.Count
        ActiveVpnOrVirtualAdapters = @($vpnLikeAdapters | ForEach-Object { [PSCustomObject]@{ Name=[string]$_.Name; InterfaceDescription=[string]$_.InterfaceDescription; InterfaceIndex=(Get-ObjectPropertyValue $_ 'InterfaceIndex') } })
        DefaultRoutes = $defaultRoutes
        IPv4DefaultRouteCount = $ipv4Routes.Count
        IPv6DefaultRouteCount = $ipv6Routes.Count
        MultipleActiveDefaultRoutes = [bool]($ipv4Routes.Count -gt 1 -or $ipv6Routes.Count -gt 1)
        EnabledBindingCount = @($allBindings | Where-Object { $_.Enabled }).Count
        EnabledThirdPartyOrFilterBindingCount = $thirdPartyBindings.Count
        EnabledThirdPartyOrFilterBindings = $thirdPartyBindings
        AdvancedPropertyCount = $advancedPropertyCount
        OffloadRecordCounts = $offloadCounts
        ActiveDnsServers = @($DnsServers | Select-Object -Unique)
        ActiveDnsDohRecordCount = $dohRecords.Count
        ActiveDnsDohRecords = $dohRecords
        TcpGlobal = [PSCustomObject]$tcpGlobal
        NetworkProfiles = $profiles
        Ncsi = [PSCustomObject][ordered]@{
            ProfileReportsInternet = $profileInternet
            DnsProbe = [PSCustomObject]$ncsiDns
            HttpProbe = [PSCustomObject]$ncsiHttp
            OperationalEventCount = $ncsiEvents.Count
            OperationalEventError = $ncsiEventError
            WinHttpProxy = [PSCustomObject]$proxyState
            MismatchDetected = $ncsiMismatch
        }
        Notes = @($notes)
    }
}

function New-NetworkStackRecommendations {
    param([object]$Stack)
    $rec = New-Object System.Collections.Generic.List[string]
    if (-not $Stack) { return @($rec) }
    if ($Stack.MultipleActiveDefaultRoutes) {
        $rec.Add('Multiple active default routes were detected. Document whether a VPN or security client is intended to be active, then compare one standard run with that state unchanged and one controlled run with only the intended path active. Do not remove routes manually.') | Out-Null
    }
    if ([int]$Stack.ActiveVpnOrVirtualAdapterCount -gt 0) {
        $rec.Add(('Active VPN/virtual-like adapters were detected ({0}). These can legitimately change DNS, MTU, route metrics, and filter paths. If symptoms persist, rerun the same diagnostic with the intended VPN state clearly labeled.' -f $Stack.ActiveVpnOrVirtualAdapterCount)) | Out-Null
    }
    if ([int]$Stack.EnabledThirdPartyOrFilterBindingCount -gt 0) {
        $rec.Add(('Enabled non-Microsoft or VPN/security-like adapter bindings were detected ({0}). Presence alone is not a fault. Do not uninstall or disable bindings broadly; if evidence points local, test one vendor feature at a time through its normal UI and retain rollback.' -f $Stack.EnabledThirdPartyOrFilterBindingCount)) | Out-Null
    }
    if ($Stack.Ncsi -and $Stack.Ncsi.MismatchDetected) {
        $rec.Add('Windows NCSI status and the reference DNS/HTTP probes disagreed. Check proxy/firewall/VPN filtering and the Microsoft-Windows-NCSI/Operational evidence before treating the taskbar Internet icon as proof of general packet loss.') | Out-Null
    }
    $autoTuning = [string]$Stack.TcpGlobal.AutoTuningLevel
    if (-not [string]::IsNullOrWhiteSpace($autoTuning) -and $autoTuning -notmatch '(?i)^normal$') {
        $rec.Add(('TCP receive-window auto-tuning is reported as "{0}" rather than normal. This can be intentional, so do not reset it automatically; preserve the snapshot and review it if throughput is abnormal.' -f $autoTuning)) | Out-Null
    }
    return @($rec)
}

function Analyze-NetworkEvents {
    param([object[]]$Events)
    $analysis = [PSCustomObject]@{ Total=0; DnsTimeout1014=0; HostsFileRead1012=0; DhcpWarnings=0; AdapterOrNdisEvents=0; RecentCriticalOrErrors=0; Notes=@() }
    try {
        $analysis.Total = @($Events).Count
        foreach ($e in @($Events)) {
            $provider = [string]$e.ProviderName
            $id = [int]$e.Id
            $level = [string]$e.LevelDisplayName
            if ($provider -match '(?i)DNS-Client' -and $id -eq 1014) { $analysis.DnsTimeout1014++ }
            if ($provider -match '(?i)DNS-Client' -and $id -eq 1012) { $analysis.HostsFileRead1012++ }
            if ($provider -match '(?i)dhcp' -and $level -match '(?i)warning|error|critical') { $analysis.DhcpWarnings++ }
            if ($provider -match '(?i)ndis|realtek|netwtw|e1d|e1r|rtwlane|killer|qcamain|athr|mtkwl|netadapter' -and $level -match '(?i)warning|error|critical') { $analysis.AdapterOrNdisEvents++ }
            if ($level -match '(?i)error|critical') { $analysis.RecentCriticalOrErrors++ }
        }
        if ($analysis.DnsTimeout1014 -gt 0) { $analysis.Notes += ('Recent DNS Client 1014 timeout events found: ' + $analysis.DnsTimeout1014) }
        if ($analysis.HostsFileRead1012 -gt 0) { $analysis.Notes += ('Recent DNS Client 1012 hosts-file read errors found: ' + $analysis.HostsFileRead1012) }
        if ($analysis.AdapterOrNdisEvents -gt 0) { $analysis.Notes += ('Recent adapter/NDIS warning/error events found: ' + $analysis.AdapterOrNdisEvents) }
    } catch { $analysis.Notes += ('Event analysis error: ' + $_.Exception.Message) }
    return $analysis
}

function Start-NetshTraceSession {
    param([bool]$IsAdmin,[switch]$Enable)
    $state = [PSCustomObject]@{ Attempted=$false; Started=$false; Directory=$netshTraceDir; EtlFile=$null; Notes=@(); Files=@() }
    if (-not $Enable) { $state.Notes += 'Skipped because -NetshTrace was not used.'; return $state }
    if (-not $IsAdmin) { $state.Notes += 'Skipped because netsh trace requires administrator rights.'; return $state }
    if (-not (Get-Command netsh.exe -ErrorAction SilentlyContinue)) { $state.Notes += 'netsh.exe was not found.'; return $state }
    $state.Attempted = $true
    New-DirectorySafe $netshTraceDir
    $etl = Join-Path $netshTraceDir 'nettrace_internetclient.etl'
    $state.EtlFile = $etl
    $args = @('trace','start','scenario=InternetClient','capture=yes','report=no',('tracefile=' + $etl),'maxsize=64','filemode=circular','overwrite=yes')
    $r = Invoke-LoggedCommand -Name 'netsh_trace_start' -Command 'netsh.exe' -Arguments $args -TimeoutSec 60 -OutputDir $netshTraceDir
    $state.Files += $r.File
    if ($r.Output -match '(?i)Trace configuration|Trace started|running' -or $r.ExitCode -eq 0) { $state.Started = $true; $state.Notes += 'netsh InternetClient trace started with circular 64 MB cap.' }
    else { $state.Notes += 'netsh trace did not report a clean start. See netsh_trace_start.txt.' }
    return $state
}

function Stop-NetshTraceSession {
    param([object]$State)
    if (-not $State) { return $State }
    try {
        if ($State.Started) {
            $stop = Invoke-LoggedCommand -Name 'netsh_trace_stop' -Command 'netsh.exe' -Arguments @('trace','stop') -TimeoutSec 180 -OutputDir $netshTraceDir
            $State.Files += $stop.File
            if ($stop.TimedOut -or $stop.ExitCode -ne 0) {
                throw ('netsh trace stop was not confirmed (exit={0}; timed_out={1}).' -f $stop.ExitCode,[bool]$stop.TimedOut)
            }
            $State.Started = $false
            if ($State.EtlFile -and (Test-Path -LiteralPath $State.EtlFile)) { $State.Files += $State.EtlFile }
            $txt = Join-Path $netshTraceDir 'nettrace_internetclient.txt'
            if ($State.EtlFile -and (Test-Path -LiteralPath $State.EtlFile)) {
                $conv = Invoke-LoggedCommand -Name 'netsh_trace_convert_txt' -Command 'netsh.exe' -Arguments @('trace','convert',('input=' + $State.EtlFile),('output=' + $txt),'dump=TXT','report=no','overwrite=yes') -TimeoutSec 240 -OutputDir $netshTraceDir
                $State.Files += $conv.File
                if (Test-Path -LiteralPath $txt) { $State.Files += $txt }
            }
            $State.Notes += 'netsh trace stopped. ETL and conversion logs were exported.'
        }
    } catch {
        $State.Notes += ('netsh trace cleanup warning: ' + $_.Exception.Message)
    } finally {
        if ($State.Started) {
            try {
                $fallbackStop = Invoke-LoggedCommand -Name 'netsh_trace_finally_stop' -Command 'netsh.exe' -Arguments @('trace','stop') -TimeoutSec 45 -OutputDir $netshTraceDir
                $State.Files += $fallbackStop.File
                if (-not $fallbackStop.TimedOut -and $fallbackStop.ExitCode -eq 0) {
                    $State.Started = $false
                    $State.Notes += 'netsh trace stop was confirmed by the cleanup retry.'
                } else {
                    $State.Notes += ('netsh cleanup retry did not confirm stop (exit={0}; timed_out={1}); trace state remains marked active.' -f $fallbackStop.ExitCode,[bool]$fallbackStop.TimedOut)
                }
            } catch {
                $State.Notes += ('netsh cleanup retry raised an error; trace state remains marked active: ' + $_.Exception.Message)
            }
        }
    }
    return $State
}

function New-AdvancedRecommendations {
    param(
        [object[]]$PingResults,
        [object]$FirstHopProbe,
        [object[]]$TcpResults,
        [object[]]$DnsTimingResults,
        [object]$EventAnalysis,
        [object[]]$AdapterDriverAnalysis,
        [object]$NetshTraceState
    )
    $rec = New-Object System.Collections.Generic.List[string]
    $gateway = $PingResults | Where-Object { $_.Label -eq 'Default gateway' } | Select-Object -First 1
    $firstHopPing = $null
    if ($FirstHopProbe -and $FirstHopProbe.FirstHop) { $firstHopPing = $PingResults | Where-Object { $_.Target -eq $FirstHopProbe.FirstHop } | Select-Object -First 1 }
    $external = @($PingResults | Where-Object { $_.Label -match '^Internet IP' })
    $badExt = @($external | Where-Object { $_.LossPct -ge 2 })
    if ($firstHopPing -and $gateway -and $gateway.LossPct -eq 0 -and $firstHopPing.LossPct -ge 2 -and $badExt.Count -ge 1) {
        $rec.Add(('The first ISP/CMTS-side hop ({0}) lost {1}% while your gateway stayed clean. If final external targets also lose packets, this supports a modem/coax/ISP-side problem; if only that hop loses packets, it may simply deprioritize ICMP.' -f $firstHopPing.Target,$firstHopPing.LossPct)) | Out-Null
    }
    if ($TcpResults) {
        $tcpBad = @($TcpResults | Where-Object { $_.TcpTestSucceeded -eq $false })
        if ($tcpBad.Count -gt 0) { $rec.Add(('TCP connectivity checks failed for {0} target(s). That matters more than isolated ICMP loss because it can affect real applications; review tcp_connectivity_tests.csv.' -f $tcpBad.Count)) | Out-Null }
        elseif ($badExt.Count -gt 0) { $rec.Add('ICMP ping loss appeared, but TCP/HTTPS connectivity checks succeeded. That does not rule out packet loss, but it makes ICMP rate-limiting/deprioritization more plausible; confirm with observe mode during real symptoms.') | Out-Null }
    }
    if ($DnsTimingResults) {
        $systemBad = @($DnsTimingResults | Where-Object { $_.Server -eq 'SYSTEM_DEFAULT' -and -not $_.Success })
        $publicOk = @($DnsTimingResults | Where-Object { ($_.Server -eq '1.1.1.1' -or $_.Server -eq '8.8.8.8') -and $_.Success })
        $slowLocal = @($DnsTimingResults | Where-Object { ($_.Server -eq 'SYSTEM_DEFAULT' -or $_.Server -match '^192\.168\.') -and $_.Success -and $_.ElapsedMs -gt 1000 })
        if ($systemBad.Count -gt 0 -and $publicOk.Count -gt 0) { $rec.Add('System/default DNS lookups failed while public DNS tests succeeded. Check router DNS forwarding, flush DNS, and temporarily test DNS servers such as 1.1.1.1 or 8.8.8.8.') | Out-Null }
        elseif ($slowLocal.Count -gt 0) { $rec.Add('Local/system DNS was slow during the test. Router DNS forwarding can cause lag even when raw packet loss is clean; compare with direct public DNS temporarily.') | Out-Null }
    }
    if ($EventAnalysis) {
        if ($EventAnalysis.DnsTimeout1014 -gt 0) { $rec.Add(('Recent Windows DNS timeout events were present ({0}). If game/app stalls line up with these, investigate router DNS forwarding or try direct public DNS as a temporary test.' -f $EventAnalysis.DnsTimeout1014)) | Out-Null }
        if ($EventAnalysis.HostsFileRead1012 -gt 0) { $rec.Add(('Windows recently logged hosts-file read errors ({0}). Check C:\Windows\System32\drivers\etc\hosts permissions/content; this is probably separate from coax packet loss but can cause name-resolution weirdness.' -f $EventAnalysis.HostsFileRead1012)) | Out-Null }
        if ($EventAnalysis.AdapterOrNdisEvents -gt 0) { $rec.Add('Recent adapter/NDIS warning/error events were found. If they occurred near symptoms, update the NIC driver and test with a different Ethernet cable/port.') | Out-Null }
    }
    if ($AdapterDriverAnalysis) {
        $old = @($AdapterDriverAnalysis | Where-Object { $_.DriverLooksOld })
        foreach ($o in $old | Select-Object -First 2) { $rec.Add(('The active adapter driver for {0} looks old ({1}, version {2}). Update from the motherboard/OEM or NIC vendor, then rerun; also test with Energy Efficient Ethernet/Green Ethernet disabled if packet loss persists.' -f $o.Name,$o.DriverDate,$o.DriverVersion)) | Out-Null }
    }
    if ($NetshTraceState -and $NetshTraceState.Attempted -and $NetshTraceState.Started) { $rec.Add('A netsh InternetClient ETL trace was captured. Use it only for deep review because it can contain more network metadata than the normal ZIP files.') | Out-Null }
    return @($rec | Select-Object -Unique)
}

function New-DiagnosticScorecard {
    param(
        [object[]]$PingResults,
        [object]$FirstHopProbe,
        [object[]]$TcpResults,
        [object]$ModemAnalysis,
        [object[]]$AdapterDelta,
        [object]$EventAnalysis,
        [object[]]$AdapterDriverAnalysis,
        [object]$PktmonState,
        [object]$NetshTraceState,
        [object]$LoadTest=$null
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $gateway = $PingResults | Where-Object { $_.Label -eq 'Default gateway' } | Select-Object -First 1
    $external = @($PingResults | Where-Object { $_.Label -match '^Internet IP' })
    $extSent = 0; $extLost = 0
    foreach ($e in $external) { $extSent += [int]$e.Sent; $extLost += [int]$e.Lost }
    $extLossPct = if ($extSent -gt 0) { [math]::Round(100.0*$extLost/$extSent,2) } else { $null }
    $adapterProblems = @($AdapterDelta | Where-Object { ($_.ReceivedPacketErrors_Delta -as [double]) -gt 0 -or ($_.OutboundPacketErrors_Delta -as [double]) -gt 0 -or ($_.ReceivedDiscardedPackets_Delta -as [double]) -gt 0 -or ($_.OutboundDiscardedPackets_Delta -as [double]) -gt 0 })
    $tcpBad = @($TcpResults | Where-Object { $_.TcpTestSucceeded -eq $false })
    $oldDrivers = @($AdapterDriverAnalysis | Where-Object { $_.DriverLooksOld })
    $lines.Add('NetLossDoctor diagnostic scorecard') | Out-Null
    $lines.Add('================================') | Out-Null
    $lines.Add(('Generated: {0}' -f (Get-Date).ToString('o'))) | Out-Null
    if ($LoadTest -and $LoadTest.Attempted) { $lines.Add(('Load test: attempted; rate limit = {0} Mbps; loaded p95 = {1} ms; latency increase = {2} ms' -f $LoadTest.LoadRateLimitMbps,$LoadTest.LoadedP95Ms,$LoadTest.LatencyIncreaseMs)) | Out-Null }
    $lines.Add('') | Out-Null
    if ($gateway) { $lines.Add(('Local PC -> router/gateway: {0}% loss, avg {1} ms, max {2} ms' -f $gateway.LossPct,$gateway.AvgMs,$gateway.MaxMs)) | Out-Null }
    if ($extLossPct -ne $null) { $lines.Add(('External IP aggregate: {0}/{1} lost = {2}% loss' -f $extLost,$extSent,$extLossPct)) | Out-Null }
    if ($FirstHopProbe -and $FirstHopProbe.FirstHop) { $lines.Add(('First ISP/CMTS-side hop candidate: {0} at traceroute hop {1}' -f $FirstHopProbe.FirstHop,$FirstHopProbe.FirstHopNumber)) | Out-Null }
    if ($tcpBad.Count -gt 0) { $lines.Add(('TCP/app-style connectivity: {0} failed target(s)' -f $tcpBad.Count)) | Out-Null } else { $lines.Add('TCP/app-style connectivity: no failed TCP checks detected') | Out-Null }
    if ($adapterProblems.Count -gt 0) { $lines.Add(('Adapter hardware counters: errors/discards increased on {0} adapter(s)' -f $adapterProblems.Count)) | Out-Null } else { $lines.Add('Adapter hardware counters: no errors/discards increased during the test') | Out-Null }
    if ($PktmonState -and $PktmonState.Started) { $lines.Add('Pktmon: collected counters/traces') | Out-Null } else { $lines.Add('Pktmon: not collected or skipped') | Out-Null }
    if ($NetshTraceState -and $NetshTraceState.Started) { $lines.Add('netsh trace: deep ETL captured') | Out-Null } else { $lines.Add('netsh trace: not enabled') | Out-Null }
    if ($ModemAnalysis -and $ModemAnalysis.HasModemText) { $lines.Add('Modem page: actual signal/event text was extracted') | Out-Null } elseif ($ModemAnalysis -and $ModemAnalysis.LoginDetected) { $lines.Add('Modem page: login page detected; manual signal/event capture still needed') | Out-Null } else { $lines.Add('Modem page: signal/event data not captured') | Out-Null }
    if ($EventAnalysis -and $EventAnalysis.Notes.Count -gt 0) { $lines.Add(('Recent Windows event notes: ' + (($EventAnalysis.Notes | Select-Object -Unique) -join '; '))) | Out-Null }
    if ($oldDrivers.Count -gt 0) { $lines.Add(('Driver note: {0} active adapter driver(s) look older than 3 years' -f $oldDrivers.Count)) | Out-Null }
    $lines.Add('') | Out-Null
    $nearCleanExternal = $false
    if ($extLossPct -ne $null -and $extSent -ge 1000 -and $extLossPct -le 0.10 -and $tcpBad.Count -eq 0) { $nearCleanExternal = $true }
    elseif ($extLossPct -ne $null -and $extLost -le 1 -and $tcpBad.Count -eq 0) { $nearCleanExternal = $true }
    if ($gateway -and $gateway.LossPct -eq 0 -and $extLossPct -ne $null -and $extLossPct -eq 0) { $lines.Add('Current run classification: clean during this test window. Use observe/full mode during symptoms to catch intermittent loss.') | Out-Null }
    elseif ($gateway -and $gateway.LossPct -eq 0 -and $nearCleanExternal) { $lines.Add(('Current run classification: near-clean during this test window. External aggregate was {0}/{1} lost ({2}%) with no failed TCP checks, so treat this as isolated ICMP noise unless symptoms line up with it.' -f $extLost,$extSent,$extLossPct)) | Out-Null }
    elseif ($gateway -and $gateway.LossPct -eq 0 -and $extLossPct -ne $null -and $extLossPct -gt 0) { $lines.Add('Current run classification: local LAN clean, external path lossy. Correlate router-WAN, modem, provider, and TCP evidence before assigning cause.') | Out-Null }
    elseif ($gateway -and $gateway.LossPct -gt 0) { $lines.Add('Current run classification: local gateway loss detected. Focus on Ethernet/Wi-Fi/router/NIC before coax.') | Out-Null }
    else { $lines.Add('Current run classification: insufficient data.') | Out-Null }
    return @($lines)
}

function Get-ModemPages {
    param([string]$DefaultGateway)
    $result = [PSCustomObject]@{
        PagesTried = 0
        PagesSaved = 0
        ExtractedFile = $null
        KeywordHits = @()
        AccessibleUrls = @()
        SavedPreviewUrls = @()
        LoginDetected = $false
        DetectedModem = $null
        PageTitles = @()
        Notes = @()
        ProbeErrorsHandled = 0
        UnauthorizedCount = 0
        TimeoutCount = 0
        OtherProbeErrorCount = 0
    }

    $urls = New-Object System.Collections.Generic.List[string]
    foreach ($u in @(
        'http://192.168.100.1/',
        'http://192.168.100.1/index.html',
        'http://192.168.100.1/status.html',
        'http://192.168.100.1/status.htm',
        'http://192.168.100.1/cmSignal.htm',
        'http://192.168.100.1/cmSignalData.htm',
        'http://192.168.100.1/RgConnect.asp',
        'http://192.168.100.1/RgEventLog.asp',
        'http://192.168.100.1/startup.html',
        'http://192.168.100.1/eventlog.html',
        'http://192.168.100.1/CableConnection.html',
        'http://192.168.0.1/',
        'http://192.168.0.1/status.html',
        'http://192.168.0.1/RgConnect.asp',
        'http://192.168.0.1/RgEventLog.asp'
    )) { $urls.Add($u) | Out-Null }
    if ($DefaultGateway -and $DefaultGateway -match '^192\.168\.') {
        $urls.Add(('http://' + $DefaultGateway + '/')) | Out-Null
        $urls.Add(('http://' + $DefaultGateway + '/status.html')) | Out-Null
    }

    $signalPattern = '(?i)dBmV|SNR|MER|DOCSIS|Downstream|Upstream|Correctable|Uncorrectable|T3|T4|Ranging|Signal\s*to\s*Noise|Locked|OFDM|OFDMA|Event\s+Log|Codeword|Channel\s+ID|Power\s*Level'
    $loginPattern = '(?i)login|password|loginName|loginPassword|Please\s+enter\s+password|Username\s*:'
    $extractedLines = New-Object System.Collections.Generic.List[string]
    foreach ($url in ($urls | Select-Object -Unique)) {
        $result.PagesTried++
        $errorCountBeforeProbe = $global:Error.Count
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 1 -ErrorAction Stop
            if ($response -and $response.Content) {
                $content = [string]$response.Content
                $title = $null
                $mTitle = [regex]::Match($content, '(?is)<title[^>]*>\s*(.*?)\s*</title>')
                if ($mTitle.Success) {
                    $title = ([regex]::Replace($mTitle.Groups[1].Value, '\s+', ' ')).Trim()
                    if ($title) { $result.PageTitles += $title }
                }
                if ($title -match '(?i)NETGEAR.*CM2050V|CM2050V') { $result.DetectedModem = 'NETGEAR CM2050V' }
                elseif ($title -match '(?i)NETGEAR') { $result.DetectedModem = 'NETGEAR cable modem/router' }
                elseif ($title -match '(?i)ARRIS|SURFboard') { $result.DetectedModem = 'ARRIS/SURFboard cable modem/router' }

                if ($content -match $loginPattern) { $result.LoginDetected = $true }

                $text = $content
                $text = [regex]::Replace($text, '(?is)<script.*?</script>', ' ')
                $text = [regex]::Replace($text, '(?is)<style.*?</style>', ' ')
                $text = [regex]::Replace($text, '(?is)<br\s*/?>', "`n")
                $text = [regex]::Replace($text, '(?is)</(tr|td|th|div|p|li|h[1-6])>', "`n")
                $text = [regex]::Replace($text, '(?is)<[^>]+>', ' ')
                $text = $text -replace '&nbsp;',' ' -replace '&amp;','&' -replace '&lt;','<' -replace '&gt;','>'
                $lines = $text -split "`r?`n" | ForEach-Object { ($_ -replace '\s+',' ').Trim() } | Where-Object { $_.Length -gt 0 }
                $interestingLines = @($lines | Where-Object { $_ -match $signalPattern -and $_ -notmatch '(?i)Manual check|No common unauthenticated|look for Downstream|Please enter password to login' })
                $interesting = ($interestingLines.Count -gt 0)

                $name = (New-SafeFileName ($url -replace '^https?://','')) + '.html'
                $file = Join-Path $modemDir $name
                if ($interesting) {
                    $content | Set-Content -LiteralPath $file -Encoding UTF8
                    $result.PagesSaved++
                    $result.AccessibleUrls += $url
                    foreach ($line in $interestingLines) {
                        $extractedLines.Add(('[{0}] {1}' -f $url, $line)) | Out-Null
                    }
                } else {
                    $preview = @('URL: ' + $url, 'Reached but did not expose signal/status/event data without login or was not a signal page.', 'HTTP status: ' + $response.StatusCode)
                    if ($title) { $preview += ('Title: ' + $title) }
                    if ($result.DetectedModem) { $preview += ('Detected modem: ' + $result.DetectedModem) }
                    if ($content -match $loginPattern) { $preview += 'Login page detected; password was not collected.' }
                    $preview += 'First 500 chars:'
                    $preview += ($content.Substring(0, [Math]::Min(500, $content.Length)))
                    $preview | Set-Content -LiteralPath $file -Encoding UTF8
                    $result.SavedPreviewUrls += $url
                    $result.AccessibleUrls += $url
                }
            }
        } catch {
            $result.ProbeErrorsHandled++
            $probeMsg = [string]$_.Exception.Message
            if ($probeMsg -match '(?i)401|Unauthorized') { $result.UnauthorizedCount++ }
            elseif ($probeMsg -match '(?i)timed out|timeout') { $result.TimeoutCount++ }
            else { $result.OtherProbeErrorCount++ }
            if ($Script:HandledNonFatalWarnings.Count -lt 20) {
                $Script:HandledNonFatalWarnings.Add(('Handled modem page probe issue: {0} -> {1}' -f $url,$probeMsg)) | Out-Null
            }
        } finally {
            while ($global:Error.Count -gt $errorCountBeforeProbe) {
                try { $global:Error.RemoveAt(0) } catch { break }
            }
        }
    }
    $extractFile = Join-Path $modemDir 'extracted_modem_status_lines.txt'
    if ($extractedLines.Count -gt 0) {
        $extractedLines | Select-Object -Unique | Set-Content -LiteralPath $extractFile -Encoding UTF8
        $result.ExtractedFile = $extractFile
        $result.KeywordHits = @($extractedLines | Select-Object -First 200)
    } else {
        $msg = New-Object System.Collections.Generic.List[string]
        $msg.Add('No actual modem signal/status/event lines were extracted automatically.') | Out-Null
        if ($result.DetectedModem) { $msg.Add(('Detected modem page: ' + $result.DetectedModem)) | Out-Null }
        if ($result.LoginDetected) { $msg.Add('A login page was detected. NetLossDoctor intentionally did not collect or submit modem passwords.') | Out-Null }
        $msg.Add('Manual check: open http://192.168.100.1/ and capture Cable Connection plus Event Log details. Look for downstream power, SNR/MER, upstream power, correctables, uncorrectables, T3/T4 timeouts, and ranging/sync errors.') | Out-Null
        $msg | Set-Content -LiteralPath $extractFile -Encoding UTF8
        $result.ExtractedFile = $extractFile
        if ($result.LoginDetected -and $result.DetectedModem -match 'NETGEAR') {
            $result.Notes += 'NETGEAR modem login page detected. Manual login is needed to capture Cable Connection and Event Log data.'
        } elseif ($result.LoginDetected) {
            $result.Notes += 'Modem/router login page detected. Manual login may be needed to capture signal/event data.'
        } else {
            $result.Notes += 'No unauthenticated signal/status/event page was found.'
        }
    }
    if ($result.ProbeErrorsHandled -gt 0) { $result.Notes += ('Handled modem probe denials/timeouts without treating them as program failures: {0} total, {1} unauthorized, {2} timeout, {3} other.' -f $result.ProbeErrorsHandled,$result.UnauthorizedCount,$result.TimeoutCount,$result.OtherProbeErrorCount) }
    $result.PageTitles = @($result.PageTitles | Select-Object -Unique)
    $result.AccessibleUrls = @($result.AccessibleUrls | Select-Object -Unique)
    $result.SavedPreviewUrls = @($result.SavedPreviewUrls | Select-Object -Unique)
    return $result
}

function Analyze-ModemText {
    param([string]$ExtractedFile,[object]$ModemPages)
    $analysis = [PSCustomObject]@{
        HasModemText = $false
        MentionsT3T4 = $false
        MentionsUncorrectables = $false
        MentionsCorrectables = $false
        DbmvValues = @()
        SnrValues = @()
        SuspiciousDbmvValues = @()
        WeakSnrValues = @()
        UncorrectableLines = @()
        DetectedModem = $null
        LoginDetected = $false
        Notes = @()
    }
    if ($ModemPages) {
        $analysis.DetectedModem = $ModemPages.DetectedModem
        $analysis.LoginDetected = [bool]$ModemPages.LoginDetected
    }
    $hasRealKeywordHits = $false
    try { if ($ModemPages -and $ModemPages.KeywordHits -and $ModemPages.KeywordHits.Count -gt 0) { $hasRealKeywordHits = $true } } catch {}
    if (-not $hasRealKeywordHits) {
        if ($analysis.LoginDetected -and $analysis.DetectedModem) {
            $analysis.Notes += ('Detected ' + $analysis.DetectedModem + ' login page, but no actual signal/event lines were extracted automatically.')
        } elseif ($analysis.LoginDetected) {
            $analysis.Notes += 'Detected a modem/router login page, but no actual signal/event lines were extracted automatically.'
        } else {
            $analysis.Notes += 'No actual modem signal/event lines were extracted automatically.'
        }
        return $analysis
    }
    if ($ExtractedFile -and (Test-Path -LiteralPath $ExtractedFile)) {

        $text = Get-Content -LiteralPath $ExtractedFile -Raw -ErrorAction SilentlyContinue
        if ($text -and ($text -match '(?i)dBmV|SNR|MER|Downstream|Upstream|DOCSIS')) { $analysis.HasModemText = $true }
        if ($text -match '(?i)T3|T4|No Ranging Response|Ranging Request|MDD|SYNC Timing|timeout') { $analysis.MentionsT3T4 = $true }
        if ($text -match '(?i)uncorrectable|uncorrectables') { $analysis.MentionsUncorrectables = $true }
        if ($text -match '(?i)correctable|correctables') { $analysis.MentionsCorrectables = $true }
        $dbmv = @([regex]::Matches($text, '(-?\d+(?:\.\d+)?)\s*dBmV') | ForEach-Object { [double]$_.Groups[1].Value })
        $snr = @([regex]::Matches($text, '(?i)(?:SNR|MER|Signal to Noise)[^\r\n-+0-9]*(-?\d+(?:\.\d+)?)\s*dB') | ForEach-Object { [double]$_.Groups[1].Value })
        $analysis.DbmvValues = @($dbmv)
        $analysis.SnrValues = @($snr)
        $analysis.SuspiciousDbmvValues = @($dbmv | Where-Object { $_ -lt -15 -or $_ -gt 55 })
        $analysis.WeakSnrValues = @($snr | Where-Object { $_ -lt 30 })
        $lines = $text -split "`r?`n"
        foreach ($line in $lines) {
            if ($line -match '(?i)uncorrectable|uncorrectables|codeword') { $analysis.UncorrectableLines += $line.Trim() }
        }
        if ($dbmv.Count -gt 0) { $analysis.Notes += ('Found dBmV values in modem text: ' + (($dbmv | Select-Object -First 40) -join ', ')) }
        if ($snr.Count -gt 0) { $analysis.Notes += ('Found SNR/MER-like dB values in modem text: ' + (($snr | Select-Object -First 40) -join ', ')) }
        if ($analysis.SuspiciousDbmvValues.Count -gt 0) { $analysis.Notes += ('Some dBmV values are outside broad sanity bounds: ' + (($analysis.SuspiciousDbmvValues | Select-Object -First 20) -join ', ')) }
        if ($analysis.WeakSnrValues.Count -gt 0) { $analysis.Notes += ('Some SNR/MER-like values are below 30 dB: ' + (($analysis.WeakSnrValues | Select-Object -First 20) -join ', ')) }
        if ($analysis.MentionsT3T4) { $analysis.Notes += 'Modem text mentions T3/T4/ranging/sync/timeout language; this often points toward coax/RF/ISP-side instability.' }
        if ($analysis.MentionsUncorrectables) { $analysis.Notes += 'Modem text mentions uncorrectables; rising uncorrectables during symptoms can point toward RF signal/noise problems.' }
    }
    return $analysis
}

function New-Recommendations {
    param(
        [object[]]$PingResults,
        [object]$WifiInfo,
        [object]$ModemAnalysis,
        [object[]]$AdapterDelta,
        [object[]]$MtuResults,
        [object]$LoadTest,
        [object]$PktmonState
    )
    $rec = New-Object System.Collections.Generic.List[string]
    $gateway = $PingResults | Where-Object { $_.Label -eq 'Default gateway' } | Select-Object -First 1
    $external = @($PingResults | Where-Object { $_.Label -match '^Internet IP' })
    $domains = @($PingResults | Where-Object { $_.Label -match '^DNS hostname' })
    $loopback = $PingResults | Where-Object { $_.Label -eq 'Loopback' } | Select-Object -First 1

    if ($loopback -and $loopback.LossPct -gt 0) {
        $rec.Add('Loopback packet loss was detected. That is unusual and points to a local Windows/network-stack problem. Reboot, update NIC drivers, temporarily disable third-party VPN/security network filters, and rerun the test.') | Out-Null
    }

    if ($gateway -and $gateway.LossPct -ge 1) {
        $rec.Add(('Loss to the default gateway was {0}%. That usually means the problem is before the modem/ISP path: Wi-Fi, Ethernet cable, switch, router port, NIC, or router load.' -f $gateway.LossPct)) | Out-Null
        if ($WifiInfo -and $WifiInfo.IsWifi) {
            $rec.Add('Because the active connection appears to be Wi-Fi, run the same test using Ethernet directly to the router or gateway. If gateway loss disappears on Ethernet, focus on Wi-Fi signal/interference, channel choice, router placement, and wireless driver updates.') | Out-Null
        } else {
            $rec.Add('Because this does not appear to be Wi-Fi, swap the Ethernet cable, try another router/switch port, bypass intermediate switches, and update the NIC driver. If available, disable Energy Efficient Ethernet/Green Ethernet on the NIC and switch for testing.') | Out-Null
        }
    } else {
        $badExternal = @($external | Where-Object { $_.LossPct -ge 2 })
        if ($external.Count -gt 0 -and $badExternal.Count -ge [Math]::Min(2,$external.Count)) {
            $avgLoss = [math]::Round((($external | Measure-Object LossPct -Average).Average),2)
            $rec.Add(('Gateway looked clean, but multiple external IP tests showed packet loss. Average external IP loss was about {0}%. Correlate router-WAN, modem, physical-link, and provider evidence before assigning cause.' -f $avgLoss)) | Out-Null
            $rec.Add('Run observe or full mode during symptoms. If external loss returns while the gateway remains clean, retain the report and ask the network provider to compare it with their telemetry.') | Out-Null
        } elseif ($external.Count -gt 0) {
            $maxExternalLoss = ($external | Measure-Object LossPct -Maximum).Maximum
            if ($maxExternalLoss -gt 0) {
                $sentTotal = 0; $lostTotal = 0
                foreach ($e in $external) { $sentTotal += [int]$e.Sent; $lostTotal += [int]$e.Lost }
                $aggregateLoss = if ($sentTotal -gt 0) { [math]::Round(100.0*$lostTotal/$sentTotal,2) } else { $maxExternalLoss }
                if (($sentTotal -ge 1000 -and $aggregateLoss -le 0.10 -and $lostTotal -le 3) -or ($lostTotal -le 1)) {
                    $rec.Add(('Near-clean result: only {0}/{1} external IP probes were lost ({2}%). With a clean gateway and no failed TCP checks, this is not enough by itself to call the path bad; rerun watch mode during symptoms if problems return.' -f $lostTotal,$sentTotal,$aggregateLoss)) | Out-Null
                } else {
                    $rec.Add(('Some external packet loss was observed, but it was not consistent across all external IP targets. Max external loss was {0}%. This can be real intermittent loss, but it can also be ICMP deprioritization by one target/path. Rerun full or observe mode during the exact time you notice lag.' -f $maxExternalLoss)) | Out-Null
                }
            } else {
                $rec.Add('No packet loss was detected during the ping window. Packet loss is often intermittent, so rerun standard or observe mode while the issue is happening.') | Out-Null
            }
        }
    }

    if ($gateway -and $gateway.MaxMs -ne $null -and $gateway.MaxMs -gt 50) {
        $rec.Add(('Gateway latency spiked to {0} ms. Spikes to the gateway are usually local congestion, Wi-Fi airtime/interference, router CPU load, or a bad Ethernet/switch path.' -f $gateway.MaxMs)) | Out-Null
    }

    if ($external.Count -gt 0) {
        $highJitter = @($external | Where-Object { ($_.P95Ms -ne $null -and $_.P95Ms -gt 100) -or ($_.P99Ms -ne $null -and $_.P99Ms -gt 150) -or ($_.JitterMs -ne $null -and $_.JitterMs -gt 40) })
        $singleOutlier = @($external | Where-Object { ($_.MaxMs -ne $null -and $_.MaxMs -gt 150) -and ($_.P99Ms -ne $null -and $_.P99Ms -lt 80) -and ($_.JitterMs -ne $null -and $_.JitterMs -lt 20) })
        if ($highJitter.Count -gt 0) {
            $rec.Add('External latency/jitter looked high by p95/p99/jitter, not just a one-off maximum. If this appears mainly during uploads/downloads, test for bufferbloat and consider enabling Smart Queue Management/SQM/QoS on the router, or lowering upload/download shaping slightly below your real line rate.') | Out-Null
        } elseif ($singleOutlier.Count -gt 0) {
            $rec.Add('One external target showed an isolated high max-latency outlier while p99/jitter stayed low. Treat that as a note, not proof of an active fault; repeat observe mode during symptoms or use full mode to test latency under load.') | Out-Null
        }
    }

    if ($LoadTest -and $LoadTest.Completed -and $LoadTest.LatencyIncreaseMs -ne $null) {
        if ($LoadTest.LatencyIncreaseMs -gt 150 -or ($LoadTest.PingResult -and $LoadTest.PingResult.MaxMs -gt 300)) {
            $rec.Add(('Latency-under-load looked bad: loaded p95 increased by about {0} ms and max ping was {1} ms. This is a bufferbloat/congestion clue; router SQM/QoS is usually a better strategy than changing coax unless modem signal errors also appear.' -f $LoadTest.LatencyIncreaseMs, $LoadTest.PingResult.MaxMs)) | Out-Null
        } elseif ($LoadTest.LatencyIncreaseMs -gt 60) {
            $rec.Add(('Latency-under-load increased by about {0} ms. This is moderate queueing; SQM/QoS may improve gaming/voice stability even if raw packet loss is low.' -f $LoadTest.LatencyIncreaseMs)) | Out-Null
        }
    }

    if ($domains.Count -gt 0 -and $external.Count -gt 0) {
        $ipOk = (@($external | Where-Object { $_.LossPct -lt 2 }).Count -ge 1)
        $domainBad = (@($domains | Where-Object { $_.LossPct -ge 50 -or $_.Notes -match 'name lookup failed' }).Count -ge 1)
        if ($ipOk -and $domainBad) {
            $rec.Add('IP pings worked but hostname tests failed or lost heavily. That can be DNS resolution trouble. Save your router DNS settings, then test with Cloudflare 1.1.1.1 or Google 8.8.8.8 DNS, flush DNS with "ipconfig /flushdns", and rerun.') | Out-Null
        }
    }

    if ($WifiInfo -and $WifiInfo.IsWifi -and $WifiInfo.SignalPercent -ne $null) {
        if ($WifiInfo.SignalPercent -lt 60) {
            $rec.Add(('Wi-Fi signal is only {0}%. Move closer to the router, prefer 5/6 GHz if near the router, prefer 2.4 GHz only for distance/penetration, reduce interference, or test Ethernet to remove Wi-Fi from the equation.' -f $WifiInfo.SignalPercent)) | Out-Null
        } elseif ($WifiInfo.SignalPercent -lt 75) {
            $rec.Add(('Wi-Fi signal is {0}%, which is usable but not ideal for diagnosing packet loss. Ethernet testing is still recommended to separate Wi-Fi from coax/ISP problems.' -f $WifiInfo.SignalPercent)) | Out-Null
        }
    }

    if ($ModemAnalysis) {
        if ($ModemAnalysis.MentionsT3T4) {
            $rec.Add('The modem status/event text mentions T3/T4/ranging/sync/timeout terms. That strengthens the case for coax/RF/ISP-side trouble. Inspect and tighten coax connectors, remove unnecessary splitters, check for damaged wall plates/jumpers, and ask the ISP to check signal levels/noise at the tap and demarc.') | Out-Null
        }
        if ($ModemAnalysis.MentionsUncorrectables) {
            $rec.Add('The modem status text mentions uncorrectables. If uncorrectable codewords rise while you are seeing packet loss, focus on downstream RF noise/SNR, damaged coax, loose fittings, splitters, or ISP plant issues.') | Out-Null
        }
        if ($ModemAnalysis.SuspiciousDbmvValues -and $ModemAnalysis.SuspiciousDbmvValues.Count -gt 0) {
            $rec.Add('Some modem dBmV values looked outside broad sanity bounds. Review MODEM_SIGNAL_CHECKLIST.txt and compare against your modem model/ISP guidance before changing hardware.') | Out-Null
        }
        if (-not $ModemAnalysis.HasModemText -and $ModemAnalysis.LoginDetected) {
            $rec.Add('A modem/router login page was detected, so no signal or event data was extracted. Follow the manufacturer''s documentation and never place credentials or session data in a report.') | Out-Null
        }
    }

    if ($AdapterDelta) {
        $statsWithErrors = @($AdapterDelta | Where-Object {
            ($_.ReceivedPacketErrors_Delta -as [double]) -gt 0 -or ($_.OutboundPacketErrors_Delta -as [double]) -gt 0 -or ($_.ReceivedDiscardedPackets_Delta -as [double]) -gt 20 -or ($_.OutboundDiscardedPackets_Delta -as [double]) -gt 20
        })
        if ($statsWithErrors.Count -gt 0) {
            $rec.Add('Windows adapter counters increased errors or discards during the test on at least one adapter. Swap cables/ports, update the NIC/Wi-Fi driver, check link speed/duplex, and temporarily remove VPN/security filter drivers.') | Out-Null
        }
    }

    if ($MtuResults) {
        $mtu1472 = $MtuResults | Where-Object { $_.PayloadBytes -eq 1472 } | Select-Object -First 1
        $mtu1400 = $MtuResults | Where-Object { $_.PayloadBytes -eq 1400 } | Select-Object -First 1
        if ($mtu1472 -and -not $mtu1472.Success -and $mtu1400 -and $mtu1400.Success) {
            $rec.Add('The DF/MTU test suggests full 1500-byte MTU may not pass while smaller packets do. This can happen with VPNs, tunnels, PPPoE, or a router/firewall path issue. Test with VPN disabled and check router WAN MTU.') | Out-Null
        }
    }

    if ($PktmonState -and $PktmonState.Attempted) {
        $rec.Add('Pktmon evidence was requested. Review its counters alongside adapter, gateway, and external-path results; no single counter proves root cause.') | Out-Null
    } elseif ($PktmonState -and $PktmonState.Notes) {
        $rec.Add(('Pktmon was not collected: ' + (($PktmonState.Notes | Select-Object -Unique) -join ' '))) | Out-Null
    }

    if ($LoadTest -and $LoadTest.Attempted) {
        $rec.Add('Treat bounded load-test throughput as context, not a certified line-speed measurement; prioritize loss, loaded p95/p99 latency, latency increase, and jitter.') | Out-Null
    }

    return @($rec | Select-Object -Unique)
}

function New-RedactedSummary {
    param([string]$Source,[string]$Destination)
    try {
        $text = Get-Content -LiteralPath $Source -Raw -ErrorAction Stop
        (Redact-NldExportText -Text $text) | Set-Content -LiteralPath $Destination -Encoding UTF8
    } catch {
        ('Could not create redacted summary: ' + $_.Exception.Message) | Set-Content -LiteralPath $Destination -Encoding UTF8
    }
}


function Add-CompactSection {
    param(
        [string]$Destination,
        [string]$Title,
        [string]$SourcePath,
        [int]$MaxLines = 140
    )
    try {
        '' | Out-File -FilePath $Destination -Append -Encoding UTF8
        ('===== ' + $Title + ' =====') | Out-File -FilePath $Destination -Append -Encoding UTF8
        ('Source: ' + (Redact-NldExportText -Text $SourcePath)) | Out-File -FilePath $Destination -Append -Encoding UTF8
        if (-not (Test-Path -LiteralPath $SourcePath)) {
            'Not collected or file not present.' | Out-File -FilePath $Destination -Append -Encoding UTF8
            return
        }
        $lines = @((Redact-NldExportText -Text (Get-Content -LiteralPath $SourcePath -Raw -ErrorAction SilentlyContinue)) -split "`r?`n")
        if ($lines.Count -le $MaxLines) {
            $lines | Out-File -FilePath $Destination -Append -Encoding UTF8
        } else {
            ('Showing first {0} and last {1} lines from {2} total lines.' -f [int]($MaxLines/2), [int]($MaxLines/2), $lines.Count) | Out-File -FilePath $Destination -Append -Encoding UTF8
            $lines | Select-Object -First ([int]($MaxLines/2)) | Out-File -FilePath $Destination -Append -Encoding UTF8
            '... [trimmed for compact support export] ...' | Out-File -FilePath $Destination -Append -Encoding UTF8
            $lines | Select-Object -Last ([int]($MaxLines/2)) | Out-File -FilePath $Destination -Append -Encoding UTF8
        }
    } catch {
        ('Could not add compact section ' + $Title + ': ' + $_.Exception.Message) | Out-File -FilePath $Destination -Append -Encoding UTF8
    }
}

function New-ConciseReportFile {
    param([string]$Destination)
    try {
        @(
            ('NetLossDoctor concise report - v' + $Script:Version),
            ('Created: ' + (Get-Date).ToString('o')),
            ('Mode: ' + $Mode),
            ('Label: ' + $Label),
            ('LoadRateLimitMbps: ' + $LoadRateLimitMbps),
            ('ExportFileLimit: ' + $ExportFileLimit),
            ''
        ) | Set-Content -LiteralPath $Destination -Encoding UTF8
        Add-CompactSection -Destination $Destination -Title 'SUMMARY_REDACTED' -SourcePath $summaryPath -MaxLines 220
        Add-CompactSection -Destination $Destination -Title 'DIAGNOSTIC_SCORECARD' -SourcePath (Join-Path $runDir 'DIAGNOSTIC_SCORECARD.txt') -MaxLines 120
        Add-CompactSection -Destination $Destination -Title 'SUGGESTED_FIXES' -SourcePath $suggestionsPath -MaxLines 120
        Add-CompactSection -Destination $Destination -Title 'REPORT_TAIL' -SourcePath $reportPath -MaxLines 260
    } catch {
        ('Could not create concise report: ' + $_.Exception.Message) | Set-Content -LiteralPath $Destination -Encoding UTF8
    }
}

function New-NetworkSnapshotCompactFile {
    param([string]$Destination)
    try {
        @(
            ('NetLossDoctor network snapshot compact - v' + $Script:Version),
            ('Created: ' + (Get-Date).ToString('o')),
            'This file merges the most useful network state into one compact file so the upload ZIP stays under the 20-file limit.',
            ''
        ) | Set-Content -LiteralPath $Destination -Encoding UTF8
        Add-CompactSection -Destination $Destination -Title 'system_summary.json' -SourcePath (Join-Path $jsonDir 'system_summary.json') -MaxLines 160
        Add-CompactSection -Destination $Destination -Title 'gateway_info.json' -SourcePath (Join-Path $jsonDir 'gateway_info.json') -MaxLines 160
        Add-CompactSection -Destination $Destination -Title 'dns_servers.json' -SourcePath (Join-Path $jsonDir 'dns_servers.json') -MaxLines 160
        Add-CompactSection -Destination $Destination -Title 'network_stack_health.json' -SourcePath (Join-Path $jsonDir 'network_stack_health.json') -MaxLines 360
        Add-CompactSection -Destination $Destination -Title 'wifi_info.json' -SourcePath (Join-Path $jsonDir 'wifi_info.json') -MaxLines 160
        Add-CompactSection -Destination $Destination -Title 'latency_under_load.json' -SourcePath (Join-Path $jsonDir 'latency_under_load.json') -MaxLines 220
        Add-CompactSection -Destination $Destination -Title 'pktmon_state_final.json' -SourcePath (Join-Path $jsonDir 'pktmon_state_final.json') -MaxLines 220
        Add-CompactSection -Destination $Destination -Title 'adapter_statistics_delta.csv' -SourcePath (Join-Path $runDir 'adapter_statistics_delta.csv') -MaxLines 160
        Add-CompactSection -Destination $Destination -Title 'Get-NetIPConfiguration' -SourcePath (Join-Path $rawDir 'Get-NetIPConfiguration.txt') -MaxLines 180
        Add-CompactSection -Destination $Destination -Title 'Get-NetAdapter' -SourcePath (Join-Path $rawDir 'Get-NetAdapter.txt') -MaxLines 140
        Add-CompactSection -Destination $Destination -Title 'ipconfig /all' -SourcePath (Join-Path $rawDir 'ipconfig_all.txt') -MaxLines 220
        Add-CompactSection -Destination $Destination -Title 'netsh int tcp show global' -SourcePath (Join-Path $rawDir 'netsh_int_tcp_show_global.txt') -MaxLines 160
        Add-CompactSection -Destination $Destination -Title 'Get-NetAdapterBinding active' -SourcePath (Join-Path $rawDir 'Get-NetAdapterBinding_active.txt') -MaxLines 180
        Add-CompactSection -Destination $Destination -Title 'Get-NetAdapterAdvancedProperty active' -SourcePath (Join-Path $rawDir 'Get-NetAdapterAdvancedProperty_active.txt') -MaxLines 180
        Add-CompactSection -Destination $Destination -Title 'Get-NetOffloadGlobalSetting' -SourcePath (Join-Path $rawDir 'Get-NetOffloadGlobalSetting.txt') -MaxLines 120
        Add-CompactSection -Destination $Destination -Title 'Get-NetTCPSetting' -SourcePath (Join-Path $rawDir 'Get-NetTCPSetting.txt') -MaxLines 180
        Add-CompactSection -Destination $Destination -Title 'Get-DnsClientDohServerAddress active' -SourcePath (Join-Path $rawDir 'Get-DnsClientDohServerAddress_active.txt') -MaxLines 100
        Add-CompactSection -Destination $Destination -Title 'NCSI Operational recent' -SourcePath (Join-Path $rawDir 'NCSI_Operational_recent.txt') -MaxLines 180
        Add-CompactSection -Destination $Destination -Title 'route print' -SourcePath (Join-Path $rawDir 'route_print.txt') -MaxLines 180
    } catch {
        ('Could not create network compact snapshot: ' + $_.Exception.Message) | Set-Content -LiteralPath $Destination -Encoding UTF8
    }
}

function New-ModemEventsCompactFile {
    param([string]$Destination)
    try {
        @(
            ('NetLossDoctor modem/events compact - v' + $Script:Version),
            ('Created: ' + (Get-Date).ToString('o')),
            'This file merges modem-page findings, network events, and local-drop clues into one compact file.',
            ''
        ) | Set-Content -LiteralPath $Destination -Encoding UTF8
        Add-CompactSection -Destination $Destination -Title 'modem_analysis.json' -SourcePath (Join-Path $jsonDir 'modem_analysis.json') -MaxLines 240
        Add-CompactSection -Destination $Destination -Title 'modem_pages.json' -SourcePath (Join-Path $jsonDir 'modem_pages.json') -MaxLines 220
        Add-CompactSection -Destination $Destination -Title 'extracted modem status lines' -SourcePath (Join-Path $modemDir 'extracted_modem_status_lines.txt') -MaxLines 220
        Add-CompactSection -Destination $Destination -Title 'network_events_analysis.json' -SourcePath (Join-Path $jsonDir 'network_events_analysis.json') -MaxLines 220
        Add-CompactSection -Destination $Destination -Title 'network_events_recent.txt' -SourcePath (Join-Path $rawDir 'network_events_recent.txt') -MaxLines 260
        Add-CompactSection -Destination $Destination -Title 'pktmon_counters_drops.txt' -SourcePath (Join-Path $pktmonDir 'pktmon_counters_drops.txt') -MaxLines 220
    } catch {
        ('Could not create modem/events compact file: ' + $_.Exception.Message) | Set-Content -LiteralPath $Destination -Encoding UTF8
    }
}

function Test-ExpectedNonFatalErrorRecord {
    param([object]$Record)
    try {
        $fid = [string]$Record.FullyQualifiedErrorId
        $msg = [string]$Record.Exception.Message
        $stack = [string]$Record.ScriptStackTrace
        if ($fid -match 'InvokeWebRequestCommand' -and ($stack -match 'Get-ModemPages' -or $msg -match '(?i)401|Unauthorized|timed out|timeout')) { return $true }
        if ($stack -match 'Get-NetworkStackHealthSnapshot' -and $msg -match '(?i)NCSI|msftconnecttest|msftncsi|specified channel could not be found|No events were found|timed out|timeout|name resolution') { return $true }
        if ($fid -match 'ERROR_TIMEOUT|RECORD_DOES_NOT_EXIST|DNS_ERROR' -and ($stack -match 'Resolve-DnsName|ResolveDNSDetails|Test-NetConnection' -or $msg -match '(?i)DNS|timed out|timeout period expired|record does not exist')) { return $true }
        if ($fid -match 'CmdletizationQuery_NotFound' -and $fid -match 'Get-NetRoute|Get-NetConnectionProfile') { return $true }
        if ($msg -match '(?i)No matching MSFT_NetRoute|No matching MSFT_NetConnectionProfile') { return $true }
    } catch {}
    return $false
}

function New-ErrorsAndWarningsFile {
    param([string]$Destination)
    try {
        @(
            ('NetLossDoctor errors and warnings - v' + $Script:Version),
            ('Created: ' + (Get-Date).ToString('o')),
            ('FatalErrorPresent: ' + [bool]$Script:FatalException),
            'Report policy: expected modem-login denials, unreachable modem pages, DNS lookup misses, and harmless Windows query misses are handled as nonfatal noise.',
            ''
        ) | Set-Content -LiteralPath $Destination -Encoding UTF8
        if ($Script:FatalException) {
            '===== FATAL ERROR =====' | Out-File -FilePath $Destination -Append -Encoding UTF8
            ($Script:FatalException | Format-List * -Force | Out-String -Width 220) | Out-File -FilePath $Destination -Append -Encoding UTF8
        }

        if ($Script:HandledNonFatalWarnings -and $Script:HandledNonFatalWarnings.Count -gt 0) {
            '===== HANDLED NONFATAL WARNINGS =====' | Out-File -FilePath $Destination -Append -Encoding UTF8
            ('Count: ' + $Script:HandledNonFatalWarnings.Count) | Out-File -FilePath $Destination -Append -Encoding UTF8
            foreach ($w in ($Script:HandledNonFatalWarnings | Select-Object -First 12)) { ('- ' + $w) | Out-File -FilePath $Destination -Append -Encoding UTF8 }
            if ($Script:HandledNonFatalWarnings.Count -gt 12) { ('... trimmed handled warnings; total: ' + $Script:HandledNonFatalWarnings.Count) | Out-File -FilePath $Destination -Append -Encoding UTF8 }
            '' | Out-File -FilePath $Destination -Append -Encoding UTF8
        }

        '===== POWERSHELL ERROR STACK SNAPSHOT =====' | Out-File -FilePath $Destination -Append -Encoding UTF8
        $errsAll = @($global:Error | Select-Object -First 80)
        $expected = @($errsAll | Where-Object { Test-ExpectedNonFatalErrorRecord $_ })
        $unexpected = @($errsAll | Where-Object { -not (Test-ExpectedNonFatalErrorRecord $_) })
        ('Expected/nonfatal records filtered from this report: ' + $expected.Count) | Out-File -FilePath $Destination -Append -Encoding UTF8
        if ($expected.Count -gt 0) {
            $groups = @($expected | Group-Object FullyQualifiedErrorId | Sort-Object Count -Descending)
            foreach ($g in ($groups | Select-Object -First 8)) { ('  - {0} x {1}' -f $g.Count,$g.Name) | Out-File -FilePath $Destination -Append -Encoding UTF8 }
        }
        '' | Out-File -FilePath $Destination -Append -Encoding UTF8
        if ($unexpected.Count -eq 0 -and -not $Script:FatalException) {
            'No unhandled PowerShell errors were present in the current session error stack at export time.' | Out-File -FilePath $Destination -Append -Encoding UTF8
        } else {
            ('Unhandled error records shown: ' + ([Math]::Min(12,$unexpected.Count))) | Out-File -FilePath $Destination -Append -Encoding UTF8
            for ($i=0; $i -lt [Math]::Min(12,$unexpected.Count); $i++) {
                $e = $unexpected[$i]
                ('--- Unhandled Error #{0} ---' -f ($i+1)) | Out-File -FilePath $Destination -Append -Encoding UTF8
                ('Type: ' + $e.Exception.GetType().FullName) | Out-File -FilePath $Destination -Append -Encoding UTF8
                ('FullyQualifiedErrorId: ' + [string]$e.FullyQualifiedErrorId) | Out-File -FilePath $Destination -Append -Encoding UTF8
                ('Message: ' + ([string]$e.Exception.Message)) | Out-File -FilePath $Destination -Append -Encoding UTF8
                if ($e.ScriptStackTrace) { $stackLines = @(([string]$e.ScriptStackTrace -split "`r?`n") | Select-Object -First 2); ('Stack: ' + ($stackLines -join ' | ')) | Out-File -FilePath $Destination -Append -Encoding UTF8 }
            }
        }
        '===== LAST EXIT CODE =====' | Out-File -FilePath $Destination -Append -Encoding UTF8
        ([string]$global:LASTEXITCODE) | Out-File -FilePath $Destination -Append -Encoding UTF8
    } catch {
        ('Could not create error report: ' + $_.Exception.Message) | Set-Content -LiteralPath $Destination -Encoding UTF8
    }
}

function New-AutoDiagProgramStateFile {
    param([string]$Destination)
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $snapshotTime = Get-Date
        $lines.Add(('NetLossDoctor auto-updating program diagnostic - v' + $Script:Version)) | Out-Null
        $lines.Add(('Created: ' + $snapshotTime.ToString('o'))) | Out-Null
        $lines.Add(('RunId: ' + $runId)) | Out-Null
        $lines.Add(('RunStarted: ' + $Script:StartTime.ToString('o'))) | Out-Null
        $lines.Add(('ElapsedSecondsMonotonic: ' + [math]::Round($Script:RunStopwatch.Elapsed.TotalSeconds,3))) | Out-Null
        $lines.Add(('CurrentStage: ' + $Script:CurrentStage)) | Out-Null
        $lines.Add(('LastProgressTime: ' + $Script:LastProgressTime.ToString('o'))) | Out-Null
        $lines.Add('ClockSources: wall_clock=Get-Date; elapsed=System.Diagnostics.Stopwatch') | Out-Null
        $lines.Add(('Script path: ' + $PSCommandPath)) | Out-Null
        $lines.Add(('Run directory: ' + $runDir)) | Out-Null
        $lines.Add(('ToolRootResolution: ' + $Script:ToolRootResolutionNote)) | Out-Null
        $lines.Add(('Mode: ' + $Mode)) | Out-Null
        $lines.Add(('Label: ' + $Label)) | Out-Null
        $lines.Add(('ExportFileLimit: ' + $ExportFileLimit)) | Out-Null
        $lines.Add('') | Out-Null
        $lines.Add('Purpose: This file auto-discovers current scripts, functions, hashes, and report inventory so future exports evolve as the program grows.') | Out-Null
        $lines.Add('') | Out-Null
        $root = $toolRoot
        if ([string]::IsNullOrWhiteSpace($root)) { $root = $PSScriptRoot }
        if ([string]::IsNullOrWhiteSpace($root) -and $PSCommandPath) { $root = Split-Path -Parent $PSCommandPath }
        $lines.Add('===== TOOL FILE INVENTORY =====') | Out-Null
        if ($root -and (Test-Path -LiteralPath $root)) {
            $toolFiles = @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(NetLossDoctor|Compare-NetLossDoctorReports|Start-NetLossDoctor|README|SECURITY|LICENSE)' } | Sort-Object Name)
            foreach ($f in $toolFiles) {
                $hash = ''
                try { $hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = 'hash_unavailable' }
                $lines.Add(('{0} | {1} bytes | modified {2:o} | sha256 {3}' -f $f.Name,$f.Length,$f.LastWriteTime,$hash)) | Out-Null
            }
        } else {
            $lines.Add('Tool folder not available.') | Out-Null
        }
        $lines.Add('') | Out-Null
        $lines.Add('===== DOCUMENTATION SNAPSHOTS =====') | Out-Null
        $releaseSnapshotNames = @(
            'README.md',
            'SECURITY.md',
            'LICENSE.md'
        )
        foreach ($releaseName in $releaseSnapshotNames) {
            $releasePath = Join-Path $root $releaseName
            $lines.Add(('--- ' + $releaseName + ' ---')) | Out-Null
            if (Test-Path -LiteralPath $releasePath) {
                try {
                    $releaseLines = @(Get-Content -LiteralPath $releasePath -ErrorAction Stop | Select-Object -First 80)
                    foreach ($releaseLine in $releaseLines) { $lines.Add((Redact-NldExportText -Text ([string]$releaseLine))) | Out-Null }
                } catch { $lines.Add(('snapshot failed: ' + $_.Exception.Message)) | Out-Null }
            } else { $lines.Add('not present in current tool folder') | Out-Null }
        }

        $lines.Add('') | Out-Null
        $lines.Add('===== FUNCTION INVENTORY =====') | Out-Null
        try {
            if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
                $source = Get-Content -LiteralPath $PSCommandPath -Raw -ErrorAction Stop
                $matches = [regex]::Matches($source,'(?m)^function\s+([A-Za-z0-9_-]+)')
                $funcs = @($matches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
                $lines.Add(('Function count: ' + $funcs.Count)) | Out-Null
                foreach ($fn in $funcs) { $lines.Add(('  - ' + $fn)) | Out-Null }
            } else { $lines.Add('Script source not available for function inventory.') | Out-Null }
        } catch { $lines.Add(('Function inventory failed: ' + $_.Exception.Message)) | Out-Null }
        $lines.Add('') | Out-Null
        $lines.Add('===== WINDOWS SECURITY CONTEXT =====') | Out-Null
        $lines.Add('DistributionForm: visible PowerShell source; no EXE, installer, packer, obfuscation, persistence, or runtime download-and-execute behavior.') | Out-Null
        $lines.Add(('NetworkResearchReviewDate: ' + $Script:NetworkResearchReviewDate)) | Out-Null
        $lines.Add(('NetworkResearchStatus: ' + $Script:NetworkResearchStatus)) | Out-Null
        $lines.Add(('NetworkStackHealthSnapshot: ' + $(if (Test-Path -LiteralPath (Join-Path $jsonDir 'network_stack_health.json')) { 'present' } elseif ($Mode -eq 'doctor') { 'not_collected_in_doctor_mode' } else { 'unavailable' }))) | Out-Null
        $lines.Add('ExecutionPolicy: the script does not modify persistent policy scopes.') | Out-Null
        try {
            foreach ($scriptFile in @('NetLossDoctor.ps1','Compare-NetLossDoctorReports.ps1')) {
                $candidate = Join-Path $root $scriptFile
                if (Test-Path -LiteralPath $candidate) {
                    $sig = Get-AuthenticodeSignature -LiteralPath $candidate -ErrorAction SilentlyContinue
                    $lines.Add(('Authenticode: {0} | status={1} | signer={2}' -f $scriptFile,[string]$sig.Status,$(if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { 'unsigned' }))) | Out-Null
                }
            }
        } catch { $lines.Add(('Authenticode check unavailable: ' + $_.Exception.Message)) | Out-Null }
        try {
            $avNames = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName } | Where-Object { $_ } | Select-Object -Unique)
            if ($avNames.Count -gt 0) { $lines.Add(('RegisteredAntivirusProducts: ' + ($avNames -join '; '))) | Out-Null }
            else { $lines.Add('RegisteredAntivirusProducts: unavailable or none reported.') | Out-Null }
        } catch { $lines.Add(('Antivirus registration check unavailable: ' + $_.Exception.Message)) | Out-Null }

        $lines.Add('') | Out-Null
        $lines.Add('===== REPORT FOLDER INVENTORY =====') | Out-Null
        try {
            $files = @(Get-ChildItem -LiteralPath $runDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '_SUPPORT_EXPORT' } | Sort-Object FullName)
            $lines.Add(('Report files discovered: ' + $files.Count)) | Out-Null
            foreach ($f in ($files | Select-Object -First 260)) {
                $rel = $f.FullName.Substring($runDir.Length).TrimStart('\','/')
                $lines.Add(('{0} | {1} bytes | modified {2:o}' -f $rel,$f.Length,$f.LastWriteTime)) | Out-Null
            }
            if ($files.Count -gt 260) { $lines.Add(('... trimmed inventory; total files: ' + $files.Count)) | Out-Null }
        } catch { $lines.Add(('Report inventory failed: ' + $_.Exception.Message)) | Out-Null }
        $lines | Set-Content -LiteralPath $Destination -Encoding UTF8
    } catch {
        ('Could not create auto diagnostic program state: ' + $_.Exception.Message) | Set-Content -LiteralPath $Destination -Encoding UTF8
    }
}


function Redact-NldExportText {
    param([string]$Text)
    try {
        $out = [string]$Text
        $projectRoot = ''
        try { $projectRoot = (Resolve-Path -LiteralPath $Script:ToolRoot -ErrorAction SilentlyContinue).Path } catch {}
        if ($projectRoot) {
            $escapedRoot = [Regex]::Escape($projectRoot.TrimEnd('\'))
            $out = [Regex]::Replace($out, $escapedRoot + '(\\[^"''\r\n,;)]*)?', '<LOCAL_PROJECT_PATH>', 'IgnoreCase')
        }
        try {
            $escapedRun = [Regex]::Escape($runDir)
            $out = [Regex]::Replace($out, $escapedRun + '(\\[^"''\r\n,;)]*)?', '<LOCAL_REPORT_PATH>', 'IgnoreCase')
        } catch {}

        # Redact remaining Windows-style local paths, private network identifiers, and common machine/user identifiers.
        $out = [Regex]::Replace($out, '(?i)\b[A-Z]:\\[^"''\r\n,;<>|]+', '<LOCAL_PATH>')
        $out = [Regex]::Replace($out, '\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[0-1])(?:\.\d{1,3}){2})\b', '<PRIVATE_IP_REDACTED>')
        $ipv6Evaluator = [Text.RegularExpressions.MatchEvaluator]{
            param($Match)
            $candidate = $Match.Value
            $addressText = ($candidate -split '%',2)[0]
            $address = $null
            if ([Net.IPAddress]::TryParse($addressText,[ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) {
                return '<IPV6_REDACTED>'
            }
            return $candidate
        }
        $out = [Regex]::Replace($out, '(?i)(?<![0-9a-f:])(?:[0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}(?:%[\w.-]+)?(?![0-9a-f:])', $ipv6Evaluator)
        $out = [Regex]::Replace($out, '(?i)\b([0-9a-f]{2}[:-]){5}[0-9a-f]{2}\b', '<MAC_REDACTED>')
        $out = [Regex]::Replace($out, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<GUID_REDACTED>')

        if ($env:USERNAME) { $out = [Regex]::Replace($out, [Regex]::Escape($env:USERNAME), '<USER_REDACTED>', 'IgnoreCase') }
        if ($env:COMPUTERNAME) { $out = [Regex]::Replace($out, [Regex]::Escape($env:COMPUTERNAME), '<COMPUTER_REDACTED>', 'IgnoreCase') }

        $out = [Regex]::Replace($out, '(?im)^(\s*"?User(Name)?\"?\s*[:=]\s*"?)[^",\r\n]+("?)', '$1<USER_REDACTED>$3')
        $out = [Regex]::Replace($out, '(?im)^(\s*"?Computer(Name)?\"?\s*[:=]\s*"?)[^",\r\n]+("?)', '$1<COMPUTER_REDACTED>$3')
        $out = [Regex]::Replace($out, '(?im)^(\s*"?SSID\"?\s*[:=]\s*"?)[^",\r\n]*("?)', '$1<SSID_REDACTED>$2')
        $out = [Regex]::Replace($out, '(?im)^(\s*"?BSSID\"?\s*[:=]\s*"?)[^",\r\n]*("?)', '$1<BSSID_REDACTED>$2')
        return $out
    } catch {
        return '<REDACTION_FAILED_TEXT_OMITTED>'
    }
}


function Add-SupportExportFile {
    param(
        [string]$StageDir,
        [string]$SourcePath,
        [string]$Name,
        [System.Collections.Generic.List[string]]$Included,
        [System.Collections.Generic.List[string]]$Omitted,
        [int]$EffectiveMax,
        [switch]$Required
    )
    try {
        if ($Included -contains $Name) {
            $Omitted.Add(('duplicate export name skipped: ' + $Name)) | Out-Null
            return
        }
        if ($Included.Count -ge $EffectiveMax) {
            $Omitted.Add(('file limit reached before ' + $Name)) | Out-Null
            return
        }
        $dest = Join-Path $StageDir $Name
        try {
            $sourceFull = [IO.Path]::GetFullPath($SourcePath)
            $stageFull = [IO.Path]::GetFullPath($StageDir).TrimEnd('\') + '\'
            if ($sourceFull.StartsWith($stageFull,[StringComparison]::OrdinalIgnoreCase)) {
                $Omitted.Add(('active export staging descendant rejected: ' + $Name)) | Out-Null
                return
            }
        } catch {}
        if (Test-Path -LiteralPath $SourcePath) {
            $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant()
            if ($ext -in @('.txt','.csv','.json','.log','.md')) {
                try {
                    $rawText = $null
                    $lastReadError = $null
                    for ($attempt = 1; $attempt -le 2; $attempt++) {
                        try {
                            $rawText = Get-Content -LiteralPath $SourcePath -Raw -ErrorAction Stop
                            $lastReadError = $null
                            break
                        } catch {
                            $lastReadError = $_.Exception.Message
                            if ($attempt -lt 2) { Start-Sleep -Milliseconds 150 }
                        }
                    }
                    if ($null -eq $rawText) { throw ('read failed after bounded retry: ' + $lastReadError) }
                    (Redact-NldExportText -Text $rawText) | Set-Content -LiteralPath $dest -Encoding UTF8
                } catch {
                    ('Text export item omitted because safe redaction failed: ' + $Name + [Environment]::NewLine + 'Reason: ' + $_.Exception.Message) | Set-Content -LiteralPath $dest -Encoding UTF8
                    $Omitted.Add(('redacted placeholder used for ' + $Name + ': ' + $_.Exception.Message)) | Out-Null
                }
            } else {
                Copy-Item -LiteralPath $SourcePath -Destination $dest -Force -ErrorAction Stop
            }
            $Included.Add($Name) | Out-Null
        } elseif ($Required) {
            ('Required export item was not collected yet: ' + $Name + [Environment]::NewLine + 'Expected source: <LOCAL_PATH_REDACTED>') | Set-Content -LiteralPath $dest -Encoding UTF8
            $Included.Add($Name) | Out-Null
        } else {
            $Omitted.Add(('not present: ' + $Name)) | Out-Null
        }
    } catch {
        $Omitted.Add(('copy failed for ' + $Name + ': ' + $_.Exception.Message)) | Out-Null
    }
}

function New-MinimalFallbackSupportZip {
    param(
        [string]$RunDir,
        [string]$ZipPath,
        [string]$Reason
    )
    $fallbackStage = Join-Path $RunDir '_SUPPORT_EXPORT_MINIMAL'
    try { if (Test-Path -LiteralPath $fallbackStage) { Remove-Item -LiteralPath $fallbackStage -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    New-DirectorySafe $fallbackStage
    $safeReason = Redact-NldExportText -Text ([string]$Reason)
    @(
        ('Project: ' + $Script:ProjectSlug),
        ('Version: ' + $Script:Version),
        'Sensitivity: support-redacted',
        ('NetLossDoctor minimal recovery export - v' + $Script:Version),
        ('Created: ' + (Get-Date).ToString('o')),
        ('RunId: ' + $runId),
        ('Mode: ' + $Mode),
        ('CurrentStage: ' + $Script:CurrentStage),
        ('Reason: ' + $safeReason),
        'This fallback is intentionally small because the normal support-export path failed.'
    ) | Set-Content -LiteralPath (Join-Path $fallbackStage 'RECOVERY_SUMMARY.txt') -Encoding UTF8

    foreach ($item in @(
        @{ Source=$redactedSummaryPath; Name='SUMMARY_REDACTED_PUBLIC_SAFE.txt' },
        @{ Source=(Join-Path $RunDir 'ERRORS_AND_WARNINGS.txt'); Name='ERRORS_AND_WARNINGS.txt' },
        @{ Source=$pathPortabilityPath; Name='PATH_PORTABILITY_CHECK.txt' }
    )) {
        try {
            if (Test-Path -LiteralPath $item.Source) {
                $text = Get-Content -LiteralPath $item.Source -Raw -ErrorAction Stop
                (Redact-NldExportText -Text $text) | Set-Content -LiteralPath (Join-Path $fallbackStage $item.Name) -Encoding UTF8
            }
        } catch {}
    }
    @(
        'NetLossDoctor minimal recovery export contents',
        ('ProjectSlug: ' + $Script:ProjectSlug),
        ('Version: ' + $Script:Version),
        'Sensitivity: support-redacted',
        ('RunId: ' + $runId),
        'FileCountCap: 5',
        'Policy: read-only, redacted, no live probes performed by the exporter.'
    ) | Set-Content -LiteralPath (Join-Path $fallbackStage 'EXPORT_CONTENTS.txt') -Encoding UTF8

    $zipParent = Split-Path -Parent $ZipPath
    if ([string]::IsNullOrWhiteSpace($zipParent)) { $zipParent = $RunDir }
    New-DirectorySafe $zipParent
    $tempZip = Join-Path $zipParent (([IO.Path]::GetFileNameWithoutExtension($ZipPath)) + '.tmp_' + $runId + '.zip')
    try {
        if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::CreateFromDirectory($fallbackStage, $tempZip)
        $archive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        try { $count = $archive.Entries.Count } finally { $archive.Dispose() }
        if ($count -lt 1 -or $count -gt 5) { throw ('Minimal fallback archive entry count was ' + $count) }
        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction Stop }
        Move-Item -LiteralPath $tempZip -Destination $ZipPath -Force -ErrorAction Stop
        return [PSCustomObject]@{ ZipPath=$ZipPath; FileCount=$count; IntegrityVerified=$true }
    } catch {
        try { if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue } } catch {}
        throw
    }
}

function New-SupportZip {
    param(
        [string]$RunDir,
        [string]$ZipPath,
        [int]$MaxFiles = 20,
        [switch]$Emergency
    )
    # Ten is the smallest safe physical archive: nine recovery-critical files plus
    # EXPORT_CONTENTS.txt. The export contract remains a hard maximum of 20 files.
    $max = [Math]::Min(20, [Math]::Max(10, $MaxFiles))
    $effectiveMax = $max - 1 # reserve one slot for EXPORT_CONTENTS.txt
    $stageDir = Join-Path $RunDir '_SUPPORT_EXPORT'
    try { if (Test-Path -LiteralPath $stageDir) { Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    New-DirectorySafe $stageDir

    $conciseReport = Join-Path $RunDir 'REPORT_CONCISE.txt'
    $networkSnapshot = Join-Path $RunDir 'NETWORK_SNAPSHOT_COMPACT.txt'
    $modemEvents = Join-Path $RunDir 'MODEM_EVENTS_COMPACT.txt'
    $errorsFile = Join-Path $RunDir 'ERRORS_AND_WARNINGS.txt'
    $autoDiag = Join-Path $RunDir 'AUTO_DIAG_PROGRAM_STATE.txt'
    New-ConciseReportFile -Destination $conciseReport
    New-NetworkSnapshotCompactFile -Destination $networkSnapshot
    New-ModemEventsCompactFile -Destination $modemEvents
    New-ErrorsAndWarningsFile -Destination $errorsFile
    New-AutoDiagProgramStateFile -Destination $autoDiag

    $included = New-Object System.Collections.Generic.List[string]
    $omitted = New-Object System.Collections.Generic.List[string]

    # Recovery-critical evidence first. This prevents optional CSVs from crowding out
    # startup/path/error/export evidence when a caller requests a smaller archive.
    Add-SupportExportFile -StageDir $stageDir -SourcePath $summaryPath -Name 'SUMMARY_REDACTED.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $runDir 'DIAGNOSTIC_SCORECARD.txt') -Name 'DIAGNOSTIC_SCORECARD.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath $suggestionsPath -Name 'SUGGESTED_FIXES.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath $conciseReport -Name 'REPORT_CONCISE.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath $pathPortabilityPath -Name 'PATH_PORTABILITY_CHECK.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath $networkSnapshot -Name 'NETWORK_SNAPSHOT_COMPACT.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath $modemEvents -Name 'MODEM_EVENTS_COMPACT.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath $errorsFile -Name 'ERRORS_AND_WARNINGS.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required
    Add-SupportExportFile -StageDir $stageDir -SourcePath $autoDiag -Name 'AUTO_DIAG_PROGRAM_STATE.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax -Required

    # Optional evidence ranked by diagnostic value.
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $jsonDir 'network_stack_health.json') -Name 'network_stack_health.json' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $jsonDir 'system_summary.json') -Name 'system_summary.json' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath $csvPath -Name 'packet_loss_tests.csv' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $runDir 'tcp_connectivity_tests.csv') -Name 'tcp_connectivity_tests.csv' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $runDir 'dns_timing_tests.csv') -Name 'dns_timing_tests.csv' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $runDir 'mtu_df_tests.csv') -Name 'mtu_df_tests.csv' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $runDir 'adapter_statistics_delta.csv') -Name 'adapter_statistics_delta.csv' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $runDir 'adapter_driver_analysis.csv') -Name 'adapter_driver_analysis.csv' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax
    Add-SupportExportFile -StageDir $stageDir -SourcePath (Join-Path $runDir 'RUN_CONFIGURATION.txt') -Name 'RUN_CONFIGURATION.txt' -Included $included -Omitted $omitted -EffectiveMax $effectiveMax

    $contentsFile = Join-Path $stageDir 'EXPORT_CONTENTS.txt'
    @(
        ('NetLossDoctor support export contents - v' + $Script:Version),
        ('Created: ' + (Get-Date).ToString('o')),
        ('RunId: ' + $runId),
        ('ProjectSlug: ' + $Script:ProjectSlug),
        ('Version: ' + $Script:Version),
        ('Sensitivity: support-redacted'),
        ('Emergency export: ' + [bool]$Emergency),
        ('MaxFiles requested: ' + $MaxFiles),
        ('MaxFiles enforced: ' + $max),
        ('Included files excluding this contents file: ' + $included.Count),
        ('Final ZIP file count must be <= ' + $max),
        ('Run folder with full raw details: <LOCAL_REPORT_FOLDER_REDACTED>'),
        'Archive policy: same-volume temporary ZIP -> open/integrity check -> entry-count check -> atomic final rename.',
        '',
        'Included files:',
        (($included | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine),
        '',
        'Omitted/trimmed notes:',
        ($(if ($omitted.Count -gt 0) { ($omitted | ForEach-Object { '  - ' + $_ }) -join [Environment]::NewLine } else { '  - none' })),
        '',
        'Coverage status:',
        '  - startup/path/error/recovery evidence: required',
        '  - network result CSVs and supporting evidence: ranked optional',
        '  - Windows network-stack, adapter binding, VPN/route, DoH, and NCSI evidence: compact required summary plus ranked JSON',
        '  - raw captures/log trees: local only unless explicitly requested',
        '',
        'Policy: this export is read-only, deterministic, redacted, and intentionally compact. Review it before sharing with a trusted support recipient.'
    ) | Set-Content -LiteralPath $contentsFile -Encoding UTF8

    $zipParent = Split-Path -Parent $ZipPath
    if ([string]::IsNullOrWhiteSpace($zipParent)) { $zipParent = $RunDir }
    New-DirectorySafe $zipParent
    $zipStem = [IO.Path]::GetFileNameWithoutExtension($ZipPath)
    $tempZip = Join-Path $zipParent ($zipStem + '.tmp_' + $runId + '.zip')
    if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue }

    try {
        Push-Location $stageDir
        try {
            if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
                Compress-Archive -Path '*' -DestinationPath $tempZip -Force -ErrorAction Stop
            } else {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                [System.IO.Compression.ZipFile]::CreateFromDirectory($stageDir, $tempZip)
            }
        } finally {
            Pop-Location
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::OpenRead($tempZip)
        try {
            $entries = @($archive.Entries)
            $finalCount = $entries.Count
            $entryNames = @($entries | ForEach-Object { $_.FullName })
        } finally {
            $archive.Dispose()
        }
        if ($finalCount -lt 1) { throw 'Temporary export ZIP contained no entries.' }
        if ($finalCount -gt $max) { throw ('Temporary export ZIP contained {0} entries; limit is {1}.' -f $finalCount,$max) }
        if ($entryNames -notcontains 'EXPORT_CONTENTS.txt') { throw 'Temporary export ZIP is missing EXPORT_CONTENTS.txt.' }

        if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction Stop }
        Move-Item -LiteralPath $tempZip -Destination $ZipPath -Force -ErrorAction Stop
        $archiveHash = ''
        try { $archiveHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $archiveHash = 'hash_unavailable' }
        return [PSCustomObject]@{
            ZipPath = $ZipPath
            FileCount = $finalCount
            StageDir = $stageDir
            Included = @($included)
            Omitted = @($omitted)
            MaxFiles = $max
            IntegrityVerified = $true
            ArchiveSha256 = $archiveHash
        }
    } catch {
        try { if (Test-Path -LiteralPath $tempZip) { Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue } } catch {}
        throw
    }
}


trap {
    $Script:CurrentStage = 'fatal_error'
    $Script:LastProgressTime = Get-Date
    $Script:FatalException = $_
    try {
        foreach ($backgroundJob in @($jobs,$dlJob,$pingJob)) {
            foreach ($jobItem in @($backgroundJob)) {
                if ($jobItem) {
                    try { Stop-Job -Job $jobItem -ErrorAction SilentlyContinue } catch {}
                    try { Remove-Job -Job $jobItem -Force -ErrorAction SilentlyContinue } catch {}
                }
            }
        }
        try { $pktmonState = Stop-PktmonSession -State $pktmonState } catch {}
        try { $netshTraceState = Stop-NetshTraceSession -State $netshTraceState } catch {}
    } catch {}
    try {
        $fatalPath = Join-Path $runDir 'FATAL_ERROR.txt'
        @(
            ('NetLossDoctor fatal error - v' + $Script:Version),
            ('Created: ' + (Get-Date).ToString('o')),
            ('Mode: ' + $Mode),
            ('Label: ' + $Label),
            '',
            ($_ | Format-List * -Force | Out-String -Width 260)
        ) | Set-Content -LiteralPath $fatalPath -Encoding UTF8
        try { Add-Report ('FATAL ERROR: ' + $_.Exception.Message) } catch {}
        try { Add-Summary ('FATAL ERROR: ' + $_.Exception.Message) } catch {}
        try { New-RedactedSummary -Source $summaryPath -Destination $redactedSummaryPath } catch {}
        if (-not $NoZip) {
            $errorZip = Join-Path $baseDir ($runName + '_ERROR_SUPPORT_EXPORT.zip')
            try {
                $zr = New-SupportZip -RunDir $runDir -ZipPath $errorZip -MaxFiles $ExportFileLimit -Emergency
                Write-Host ''
                Write-Host 'NetLossDoctor hit an error, but created a concise support ZIP for review:'
                Write-Host $errorZip
            } catch {
                $primaryExportError = $_.Exception.Message
                $fallbackZip = Join-Path $baseDir ($runName + '_MINIMAL_ERROR_SUPPORT_EXPORT.zip')
                try {
                    $fallbackResult = New-MinimalFallbackSupportZip -RunDir $runDir -ZipPath $fallbackZip -Reason $primaryExportError
                    Write-Host 'The normal emergency export failed, but a minimal recovery ZIP was created:'
                    Write-Host $fallbackZip
                } catch {
                    Write-Host 'NetLossDoctor hit an error and could not create either support ZIP.'
                    Write-Host ('Primary export error: ' + $primaryExportError)
                    Write-Host ('Fallback export error: ' + $_.Exception.Message)
                }
            }
        }
    } catch {
        Write-Host 'NetLossDoctor fatal-error handler also failed:'
        Write-Host $_.Exception.Message
    }
    exit 1
}

Set-NldProgress 'startup_ready'
Clear-Host
Write-ConsoleLine ('NetLossDoctor {0} - Windows network diagnostic' -f $Script:Version)
Write-ConsoleLine ('Mode: {0}' -f $Mode)
if (-not [string]::IsNullOrWhiteSpace($Label)) { Write-ConsoleLine ('Run label: {0}' -f $Label) }
Write-ConsoleLine ('Report folder: {0}' -f $runDir)
Write-ConsoleLine ''

$isAdmin = Test-IsAdmin
$pingCount = 30
$pingTimeoutMs = 1000
$pathpingQueries = 10
$runPathping = $true
if ($Mode -eq 'quick') { $pingCount = 10; $runPathping = $false }
if ($Mode -eq 'appcheck') { $pingCount = 12; $runPathping = $false }
if ($Mode -eq 'full') { $pingCount = 100; $pathpingQueries = 25 }
if ($Mode -eq 'observe') { $pingCount = 300; $pathpingQueries = 10 }
if ($DurationSeconds -gt 0) { $pingCount = [Math]::Max(5, [int]$DurationSeconds) }
if ($Count -gt 0) { $pingCount = $Count }

Add-Report ('NetLossDoctor {0}' -f $Script:Version)
Add-Report ('Started: {0}' -f (Get-Date).ToString('o'))
Add-Report ('Computer: {0}' -f $env:COMPUTERNAME)
Add-Report ('User: {0}' -f $env:USERNAME)
Add-Report ('Mode: {0}' -f $Mode)
if (-not [string]::IsNullOrWhiteSpace($Label)) { Add-Report ('Label: {0}' -f $Label) }
Add-Report ('Ping count per target: {0}' -f $pingCount)
Add-Report ('LoadRateLimitMbps: {0}; LoadBytes: {1}' -f $LoadRateLimitMbps, $LoadBytes)
Add-Report ('ExportFileLimit: {0}; DefaultExportPolicy: one compact support ZIP' -f $ExportFileLimit)
Add-Report ('Running as administrator: {0}' -f $isAdmin)
Add-Report ('Tool root: {0}' -f $toolRoot)
Add-Report ('ReportsRoot input: {0}' -f $(if ([string]::IsNullOrWhiteSpace($ReportsRoot)) { '<default>' } else { '<custom provided>' }))
Add-Report ('ReportsRoot resolution note: {0}' -f $Script:ReportsRootResolutionNote)
Add-Report ('Report folder: {0}' -f $runDir)
Add-Report ''

Add-Summary ('NetLossDoctor {0}' -f $Script:Version)
Add-Summary ('Started: {0}' -f (Get-Date).ToString('o'))
Add-Summary ('Mode: {0}; Label: {1}; Ping count per target: {2}; Admin: {3}; LoadRateLimitMbps: {4}' -f $Mode, $Label, $pingCount, $isAdmin, $LoadRateLimitMbps)
Add-Summary ('Report folder: {0}' -f $runDir)
Add-Summary ''

if ($Mode -eq 'doctor') {
    Set-NldProgress 'doctor_self_test'
    Write-ConsoleLine 'Running program self-diagnostic and compact export check...'
    $systemSummary = [PSCustomObject]@{
        Version = $Script:Version
        Started = $Script:StartTime.ToString('o')
        RunId = $runId
        NetworkResearchReviewDate = $Script:NetworkResearchReviewDate
        NetworkResearchStatus = $Script:NetworkResearchStatus
        ToolRootResolution = $Script:ToolRootResolutionNote
        ReportsRootResolution = $Script:ReportsRootResolutionNote
        Mode = $Mode
        Label = $Label
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        IsAdmin = $isAdmin
        OS = $(try { ((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption + ' ' + (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Version) } catch { '' })
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        LoadRateLimitMbps = $LoadRateLimitMbps
        LoadBytes = $LoadBytes
        ExportFileLimit = $ExportFileLimit
        DryRun = [bool]$DryRun
        NoLoad = [bool]$NoLoad
        EnablePktmon = [bool]$EnablePktmon
        NetshTrace = [bool]$NetshTrace
    }
    Save-JsonSafe -Name 'system_summary' -Object $systemSummary | Out-Null
    Add-Report 'Doctor mode: no packet-loss or load test was run. This checks the program/export path and creates a concise support ZIP.'
    Add-Report ''
    Add-Summary 'Doctor mode: program/export self-test only; no packet-loss or load test was run.'
    Add-Summary ''
    'Doctor mode scorecard' | Set-Content -LiteralPath (Join-Path $runDir 'DIAGNOSTIC_SCORECARD.txt') -Encoding UTF8
    ('Version: ' + $Script:Version) | Out-File -FilePath (Join-Path $runDir 'DIAGNOSTIC_SCORECARD.txt') -Append -Encoding UTF8
    'Default invocation: local doctor self-test; no network probes.' | Out-File -FilePath (Join-Path $runDir 'DIAGNOSTIC_SCORECARD.txt') -Append -Encoding UTF8
    ('Export limit enforced: <= ' + ([Math]::Min(20,[Math]::Max(10,$ExportFileLimit))) + ' files') | Out-File -FilePath (Join-Path $runDir 'DIAGNOSTIC_SCORECARD.txt') -Append -Encoding UTF8
    'Suggested fixes / next tests' | Set-Content -LiteralPath $suggestionsPath -Encoding UTF8
    '============================' | Out-File -FilePath $suggestionsPath -Append -Encoding UTF8
    '1. Use -Mode quick or -Mode standard for active baselines, -Mode observe for intermittent symptoms, and -Mode appcheck for DNS/TCP checks.' | Out-File -FilePath $suggestionsPath -Append -Encoding UTF8
    '2. Review the doctor support ZIP before sharing it with a trusted support recipient.' | Out-File -FilePath $suggestionsPath -Append -Encoding UTF8
    $readmeOut = Join-Path $runDir 'HOW_TO_SHARE.txt'
    @"
How to share this doctor-mode report

1. Review the ZIP created beside this report folder.
2. Remove any data that should not leave the computer.
3. Share it only with a trusted support recipient through an approved channel.
4. Include the exact command and any visible error separately.
"@ | Set-Content -LiteralPath $readmeOut -Encoding UTF8
    New-RedactedSummary -Source $summaryPath -Destination $redactedSummaryPath
    $zipPath = Join-Path $baseDir ($runName + '_SUPPORT_EXPORT.zip')
    if (-not $NoZip) {
        Set-NldProgress 'doctor_export'
        Write-ConsoleLine 'Creating compact support ZIP...'
        $zipResult = New-SupportZip -RunDir $runDir -ZipPath $zipPath -MaxFiles $ExportFileLimit
        ('Export ZIP: ' + $zipPath) | Set-Content -LiteralPath (Join-Path $runDir 'ZIP_PATH.txt') -Encoding UTF8
        Add-Report ('Compact export ZIP: {0}' -f $zipPath)
        Add-Report ('Compact export file count: {0}' -f $zipResult.FileCount)
        Add-Report ('Compact export integrity verified: {0}; SHA256: {1}' -f $zipResult.IntegrityVerified,$zipResult.ArchiveSha256)
        Add-Summary ('Review before sharing with a trusted support recipient: {0}' -f $zipPath)
    }
    Write-ConsoleLine ''
    Set-NldProgress 'complete'
    Write-ConsoleLine 'Doctor mode complete.'
    Write-ConsoleLine ('Report folder: {0}' -f $runDir)
    if ($zipPath) { Write-ConsoleLine ('Export ZIP: {0}' -f $zipPath) }
    exit 0
}

Set-NldProgress 'collecting_network_configuration'
Write-ConsoleLine 'Collecting Windows network configuration...'
$os = $null
try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue } catch {}
$osText = $null
if ($os) { $osText = $os.Caption + ' ' + $os.Version }
$systemSummary = [PSCustomObject]@{
    Version = $Script:Version
    Started = $Script:StartTime.ToString('o')
    RunId = $runId
    ToolRootResolution = $Script:ToolRootResolutionNote
    ReportsRootResolution = $Script:ReportsRootResolutionNote
    Mode = $Mode
    Label = $Label
    ComputerName = $env:COMPUTERNAME
    UserName = $env:USERNAME
    IsAdmin = $isAdmin
    OS = $osText
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    LoadRateLimitMbps = $LoadRateLimitMbps
    LoadBytes = $LoadBytes
    ExportFileLimit = $ExportFileLimit
    DryRun = [bool]$DryRun
    NoLoad = [bool]$NoLoad
    EnablePktmon = [bool]$EnablePktmon
    NetshTrace = [bool]$NetshTrace
}
Save-JsonSafe -Name 'system_summary' -Object $systemSummary | Out-Null

Invoke-LoggedCommand -Name 'ipconfig_all' -Command 'ipconfig.exe' -Arguments @('/all') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'route_print' -Command 'route.exe' -Arguments @('print') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'arp_a' -Command 'arp.exe' -Arguments @('-a') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netstat_e_before' -Command 'netstat.exe' -Arguments @('-e') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netstat_s_before' -Command 'netstat.exe' -Arguments @('-s') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_int_tcp_show_global' -Command 'netsh.exe' -Arguments @('int','tcp','show','global') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_int_tcp_show_heuristics' -Command 'netsh.exe' -Arguments @('int','tcp','show','heuristics') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_int_tcp_show_supplemental' -Command 'netsh.exe' -Arguments @('int','tcp','show','supplemental') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_int_udp_show_global' -Command 'netsh.exe' -Arguments @('int','udp','show','global') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_interface_ipv4_show_interfaces' -Command 'netsh.exe' -Arguments @('interface','ipv4','show','interfaces') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_wlan_show_interfaces' -Command 'netsh.exe' -Arguments @('wlan','show','interfaces') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_wlan_show_drivers' -Command 'netsh.exe' -Arguments @('wlan','show','drivers') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netsh_wlan_show_networks_bssid' -Command 'netsh.exe' -Arguments @('wlan','show','networks','mode=bssid') -TimeoutSec 60 | Out-Null
Invoke-LoggedCommand -Name 'nslookup_google' -Command 'nslookup.exe' -Arguments @('google.com') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'nslookup_cloudflare' -Command 'nslookup.exe' -Arguments @('cloudflare.com') -TimeoutSec 45 | Out-Null

$adapterStatsBefore = @(Get-AdapterStatsSnapshot -Name 'before')
if ($adapterStatsBefore.Count -gt 0) {
    $adapterStatsBefore | Export-Csv -LiteralPath (Join-Path $runDir 'adapter_statistics_before.csv') -NoTypeInformation -Encoding UTF8
    Save-JsonSafe -Name 'adapter_statistics_before' -Object $adapterStatsBefore -Depth 6 | Out-Null
}

if (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) {
    Save-TextBlock -Name 'Get-NetAdapter' -ScriptBlock { Get-NetAdapter | Sort-Object Status,Name | Format-Table -AutoSize Name,InterfaceDescription,Status,LinkSpeed,MacAddress,MediaType,DriverInformation } | Out-Null
}
if (Get-Command Get-NetAdapterStatistics -ErrorAction SilentlyContinue) {
    Save-TextBlock -Name 'Get-NetAdapterStatistics_before' -ScriptBlock { Get-NetAdapterStatistics | Format-List * } | Out-Null
}
if (Get-Command Get-NetConnectionProfile -ErrorAction SilentlyContinue) {
    Save-TextBlock -Name 'Get-NetConnectionProfile' -ScriptBlock { Get-NetConnectionProfile -ErrorAction SilentlyContinue | Format-List * } | Out-Null
}
if (Get-Command Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
    Save-TextBlock -Name 'Get-NetIPConfiguration' -ScriptBlock { Get-NetIPConfiguration -Detailed | Format-List * } | Out-Null
}
try {
    Save-TextBlock -Name 'Win32_PnPSignedDriver_NET' -ScriptBlock { Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceClass -eq 'NET' } | Sort-Object DeviceName | Format-Table -AutoSize DeviceName,DriverVersion,DriverDate,Manufacturer,InfName } | Out-Null
} catch {}
if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
    Save-TextBlock -Name 'Resolve-DnsName_common_hosts' -ScriptBlock { 'cloudflare.com','google.com','dns.google' | ForEach-Object { Resolve-DnsName $_ -ErrorAction SilentlyContinue | Format-Table -AutoSize; '' } } | Out-Null
}

Set-NldProgress 'collecting_network_events'
Write-ConsoleLine 'Collecting recent network-related Windows events...'
$eventFile = Join-Path $rawDir 'recent_network_system_events.txt'
$networkEvents = @()
try {
    $since = (Get-Date).AddDays(-7)
    $networkEvents = @(Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$since} -MaxEvents 2000 -ErrorAction SilentlyContinue |
        Where-Object { $_.ProviderName -match '(?i)tcpip|dhcp|dns|netwtw|wlan|ndis|netbt|e1d|e1r|rtwlane|realtek|killer|bth|network|nla|netprofm|qcamain|athr|mtkwl|netadapter' } |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message -First 300)
    if ($networkEvents.Count -gt 0) { $networkEvents | Format-List * | Out-String -Width 500 | Set-Content -LiteralPath $eventFile -Encoding UTF8 }
    else { 'No matching network-related System events found in the last 7 days, or access was denied.' | Set-Content -LiteralPath $eventFile -Encoding UTF8 }
} catch { ('Could not collect network events: ' + $_.Exception.Message) | Set-Content -LiteralPath $eventFile -Encoding UTF8 }
Save-JsonSafe -Name 'network_events_recent' -Object $networkEvents -Depth 6 | Out-Null
$eventAnalysis = Analyze-NetworkEvents -Events $networkEvents
Save-JsonSafe -Name 'network_events_analysis' -Object $eventAnalysis -Depth 5 | Out-Null

$gatewayInfo = @(Get-DefaultGatewayInfo)
$defaultGateway = $null
if ($gatewayInfo.Count -gt 0) { $defaultGateway = ($gatewayInfo | Sort-Object RouteMetric | Select-Object -First 1).Gateway }
$dnsServers = @(Get-DnsServersSafe)
Save-JsonSafe -Name 'gateway_info' -Object $gatewayInfo -Depth 5 | Out-Null
Save-JsonSafe -Name 'dns_servers' -Object $dnsServers -Depth 5 | Out-Null

Set-NldProgress 'collecting_network_stack_health'
Write-ConsoleLine 'Collecting Windows network-stack, VPN/filter, DoH, and NCSI context...'
$networkStackHealth = Get-NetworkStackHealthSnapshot -DnsServers $dnsServers -GatewayInfo $gatewayInfo
Save-JsonSafe -Name 'network_stack_health' -Object $networkStackHealth -Depth 9 | Out-Null

$wifiInfo = Get-WifiSignalInfo
Save-JsonSafe -Name 'wifi_info' -Object $wifiInfo -Depth 5 | Out-Null
$wlanReport = Collect-WlanReport -IsAdmin $isAdmin -WifiInfo $wifiInfo
Save-JsonSafe -Name 'wlan_report' -Object $wlanReport -Depth 5 | Out-Null

Set-NldProgress 'probing_first_hop'
Write-ConsoleLine 'Probing first ISP/CMTS-side hop candidate...'
$firstHopProbe = Get-FirstHopProbe -DefaultGateway $defaultGateway
Save-JsonSafe -Name 'first_hop_probe' -Object $firstHopProbe -Depth 6 | Out-Null
$firstHopEchoProbe = $null
if ($firstHopProbe -and $firstHopProbe.FirstHop) {
    $firstHopEchoProbe = Test-FirstHopEchoProbe -Target $firstHopProbe.FirstHop
    Save-JsonSafe -Name 'first_hop_echo_probe' -Object $firstHopEchoProbe -Depth 6 | Out-Null
}

$adapterDriverAnalysis = @(Get-AdapterDriverAnalysis -GatewayInfo $gatewayInfo)
if ($adapterDriverAnalysis.Count -gt 0) {
    $adapterDriverAnalysis | Export-Csv -LiteralPath (Join-Path $runDir 'adapter_driver_analysis.csv') -NoTypeInformation -Encoding UTF8
    Save-JsonSafe -Name 'adapter_driver_analysis' -Object $adapterDriverAnalysis -Depth 6 | Out-Null
}

Add-Report 'Detected routing basics:'
if ($defaultGateway) { Add-Report ('  Default gateway: {0}' -f $defaultGateway) } else { Add-Report '  Default gateway: not detected' }
if ($dnsServers.Count -gt 0) { Add-Report ('  DNS servers: {0}' -f ($dnsServers -join ', ')) } else { Add-Report '  DNS servers: not detected' }
if ($wifiInfo.IsWifi) { Add-Report ('  Wi-Fi: connected; signal={0}%; RSSI={1}; radio={2}; channel={3}' -f $wifiInfo.SignalPercent, $wifiInfo.RSSIDbm, $wifiInfo.RadioType, $wifiInfo.Channel) } else { Add-Report '  Wi-Fi: not detected as the active connection, or netsh did not report a connected Wi-Fi interface.' }
if ($wlanReport.Saved) { Add-Report ('  WLAN report saved: {0}' -f $wlanReport.File) }
if ($firstHopProbe -and $firstHopProbe.FirstHop) { Add-Report ('  First ISP/CMTS-side hop candidate: {0} at hop {1}' -f $firstHopProbe.FirstHop,$firstHopProbe.FirstHopNumber) }
if ($firstHopEchoProbe -and $firstHopEchoProbe.Notes) { foreach ($n in @($firstHopEchoProbe.Notes)) { Add-Report ('  First-hop echo note: ' + $n) } }
if ($adapterDriverAnalysis.Count -gt 0) { foreach ($drv in $adapterDriverAnalysis) { Add-Report ('  Active adapter: {0}; {1}; driver {2} from {3}' -f $drv.Name,$drv.LinkSpeed,$drv.DriverVersion,$drv.DriverDate) } }
if ($networkStackHealth) {
    Add-Report ('  Network stack: active adapters={0}; VPN/virtual-like={1}; IPv4 default routes={2}; IPv6 default routes={3}' -f $networkStackHealth.ActiveAdapterCount,$networkStackHealth.ActiveVpnOrVirtualAdapterCount,$networkStackHealth.IPv4DefaultRouteCount,$networkStackHealth.IPv6DefaultRouteCount)
    Add-Report ('  Adapter bindings: enabled={0}; non-Microsoft or VPN/security-like={1}; DoH records for active DNS={2}' -f $networkStackHealth.EnabledBindingCount,$networkStackHealth.EnabledThirdPartyOrFilterBindingCount,$networkStackHealth.ActiveDnsDohRecordCount)
    Add-Report ('  NCSI: profile Internet={0}; DNS probe={1}; HTTP probe={2}; mismatch={3}; Operational events={4}' -f $networkStackHealth.Ncsi.ProfileReportsInternet,$networkStackHealth.Ncsi.DnsProbe.Success,$networkStackHealth.Ncsi.HttpProbe.Success,$networkStackHealth.Ncsi.MismatchDetected,$networkStackHealth.Ncsi.OperationalEventCount)
    foreach ($stackNote in @($networkStackHealth.Notes)) { Add-Report ('  Network-stack note: ' + $stackNote) }
}
if ($eventAnalysis -and $eventAnalysis.Notes.Count -gt 0) { foreach ($n in $eventAnalysis.Notes) { Add-Report ('  Event note: ' + $n) } }
Add-Report ''

Set-NldProgress 'building_target_list'
Write-ConsoleLine 'Building packet-loss target list...'
$targets = New-Object System.Collections.Generic.List[object]
function Add-Target {
    param([string]$Label,[string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { return }
    foreach ($t in $targets) { if ($t.Target -eq $Target -and $t.Label -eq $Label) { return } }
    $targets.Add([PSCustomObject]@{Label=$Label; Target=$Target}) | Out-Null
}

Add-Target -Label 'Loopback' -Target '127.0.0.1'
if ($defaultGateway) { Add-Target -Label 'Default gateway' -Target $defaultGateway }
foreach ($dns in ($dnsServers | Select-Object -Unique -First 2)) { Add-Target -Label ('DNS server ' + $dns) -Target $dns }
Add-Target -Label 'Internet IP Cloudflare 1.1.1.1' -Target '1.1.1.1'
Add-Target -Label 'Internet IP Google 8.8.8.8' -Target '8.8.8.8'
if ($Mode -ne 'quick') { Add-Target -Label 'Internet IP Quad9 9.9.9.9' -Target '9.9.9.9' }
if ($firstHopProbe -and $firstHopProbe.FirstHop) {
    if ($firstHopEchoProbe -and $firstHopEchoProbe.Responsive) {
        Add-Target -Label ('First ISP/CMTS hop ' + $firstHopProbe.FirstHop) -Target $firstHopProbe.FirstHop
    } else {
        Add-Report ('Skipping long ping target for first ISP/CMTS hop {0} because it did not respond to the brief ordinary-echo probe. Intermediate hops can ignore ping while still forwarding traffic normally.' -f $firstHopProbe.FirstHop)
    }
}
Add-Target -Label 'DNS hostname cloudflare.com' -Target 'cloudflare.com'
if ($Mode -ne 'quick') { Add-Target -Label 'DNS hostname google.com' -Target 'google.com' }
if (-not [string]::IsNullOrWhiteSpace($ExtraTargets)) {
    foreach ($xt in ($ExtraTargets -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) { Add-Target -Label ('Extra target ' + $xt) -Target $xt }
}

Set-NldProgress 'starting_optional_packet_capture'
Write-ConsoleLine 'Checking explicitly opted-in Pktmon collection...'
$pktmonState = $null
$netshTraceState = $null
try {
$pktmonState = Start-PktmonSession -IsAdmin $isAdmin -ModeName $Mode -Skip:(-not $EnablePktmon)
Save-JsonSafe -Name 'pktmon_state_started' -Object $pktmonState -Depth 6 | Out-Null
$netshTraceState = Start-NetshTraceSession -IsAdmin $isAdmin -Enable:$NetshTrace
Save-JsonSafe -Name 'netsh_trace_state_started' -Object $netshTraceState -Depth 6 | Out-Null

Set-NldProgress 'running_packet_loss_tests'
Write-ConsoleLine 'Running packet-loss tests in parallel...'
$jobs = @()
$directData = @()
foreach ($t in $targets) {
    $j = Start-PingJobSafe -Label $t.Label -Target $t.Target -PingCount $pingCount -TimeoutMs $pingTimeoutMs
    if ($j -and $j.PSObject.Properties['DirectPingData'] -and $j.DirectPingData) { $directData += $j }
    elseif ($j -and ($j.GetType().Name -match 'Job')) { $jobs += $j }
    elseif ($j) { $directData += $j }
}

$waitSeconds = [Math]::Max(30, ($pingCount * 2 + 30))
if ($jobs.Count -gt 0) { Wait-Job -Job $jobs -Timeout $waitSeconds | Out-Null }

$pingResults = @()
$pingSamples = @()
foreach ($d in $directData) {
    $st = Get-Date
    try { $st = [datetime]::Parse($d.StartTime) } catch {}
    $pingResults += Parse-PingOutput -Label $d.Label -Target $d.Target -Output $d.Output -ExpectedCount $pingCount -File $d.File -StartTime $st
    $pingSamples += Get-PingSamplesFromOutput -Label $d.Label -Target $d.Target -Output $d.Output -StartTime $st
}
foreach ($job in $jobs) {
    $timedOut = $false
    if ($job.State -ne 'Completed') { $timedOut = $true; try { Stop-Job -Job $job -ErrorAction SilentlyContinue } catch {} }
    $data = Receive-Job -Job $job -ErrorAction SilentlyContinue
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
    if ($data) {
        foreach ($d in @($data)) {
            $st = Get-Date
            try { $st = [datetime]::Parse($d.StartTime) } catch {}
            $pingResults += Parse-PingOutput -Label $d.Label -Target $d.Target -Output $d.Output -ExpectedCount $pingCount -File $d.File -TimedOut:$timedOut -StartTime $st
            $pingSamples += Get-PingSamplesFromOutput -Label $d.Label -Target $d.Target -Output $d.Output -StartTime $st
        }
    } else {
        $label = $job.Name
        $pingResults += [PSCustomObject]@{ Label=$label; Target='unknown'; Sent=$pingCount; Received=0; Lost=$pingCount; LossPct=100; MinMs=$null; AvgMs=$null; MaxMs=$null; P95Ms=$null; P99Ms=$null; LatencySpreadMs=$null; JitterMs=$null; MaxConsecutiveLoss=$pingCount; Notes='no ping job output'; RawLog='' }
    }
}

$pingResults = @($pingResults | Sort-Object Label,Target)
$pingResults | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
if ($pingSamples.Count -gt 0) { $pingSamples | Sort-Object Label,Target,SampleIndex | Export-Csv -LiteralPath $samplesCsvPath -NoTypeInformation -Encoding UTF8 }
Save-JsonSafe -Name 'packet_loss_tests' -Object $pingResults -Depth 5 | Out-Null
Save-JsonSafe -Name 'packet_loss_samples' -Object $pingSamples -Depth 5 | Out-Null

Add-Report 'Packet-loss test results:'
$pingTableText = $pingResults | Format-Table -AutoSize Label,Target,Sent,Received,Lost,LossPct,AvgMs,MaxMs,P95Ms,JitterMs,MaxConsecutiveLoss,Notes | Out-String -Width 260
Add-Report $pingTableText
Add-Report ('Raw ping logs are in: {0}' -f $rawDir)
Add-Report ('Per-sample CSV: {0}' -f $samplesCsvPath)
Add-Report ''

Add-Summary 'Packet-loss results:'
$pingTableText2 = $pingResults | Format-Table -AutoSize Label,Target,Sent,Received,Lost,LossPct,AvgMs,MaxMs,P95Ms,JitterMs,MaxConsecutiveLoss,Notes | Out-String -Width 260
Add-Summary $pingTableText2
Add-Summary ''

Set-NldProgress 'running_mtu_tests'
Write-ConsoleLine 'Running MTU sanity tests...'
$mtuResults = @(Invoke-MtuTests)
$mtuResults | Export-Csv -LiteralPath (Join-Path $runDir 'mtu_df_tests.csv') -NoTypeInformation -Encoding UTF8
Save-JsonSafe -Name 'mtu_df_tests' -Object $mtuResults -Depth 5 | Out-Null
Add-Report 'MTU/DF sanity tests:'
Add-Report (($mtuResults | Format-Table -AutoSize PayloadBytes,ApproxEthernetMTU,Success,FragmentationMessage,TimeoutOrFailure | Out-String -Width 200))
Add-Report ''

Set-NldProgress 'running_tcp_dns_tests'
Write-ConsoleLine 'Running TCP/HTTPS and DNS timing probes...'
$tcpResults = @(Invoke-TcpConnectivityTests)
$tcpResults | Export-Csv -LiteralPath (Join-Path $runDir 'tcp_connectivity_tests.csv') -NoTypeInformation -Encoding UTF8
Save-JsonSafe -Name 'tcp_connectivity_tests' -Object $tcpResults -Depth 6 | Out-Null
Add-Report 'TCP/app-style connectivity checks:'
Add-Report (($tcpResults | Format-Table -AutoSize Label,Host,Port,TcpTestSucceeded,PingSucceeded,ElapsedMs,RemoteAddress,Error | Out-String -Width 260))
Add-Report ''

$dnsTimingResults = @(Invoke-DnsTimingTests -DnsServers $dnsServers)
if ($dnsTimingResults.Count -eq 0) {
    $dnsTimingResults = @([PSCustomObject]@{ Host=''; Server=''; Success=$false; ElapsedMs=0; TimedOut=$false; ErrorHint='DNS timing probe produced no rows; this is a tool-side collection failure, not proof of a DNS fault.'; RawLog='' })
}
$dnsTimingResults | Export-Csv -LiteralPath (Join-Path $runDir 'dns_timing_tests.csv') -NoTypeInformation -Encoding UTF8
Save-JsonSafe -Name 'dns_timing_tests' -Object $dnsTimingResults -Depth 6 | Out-Null
Add-Report 'DNS timing checks:'
Add-Report (($dnsTimingResults | Format-Table -AutoSize Host,Server,Success,ElapsedMs,TimedOut,ErrorHint | Out-String -Width 260))
Add-Report ''

$loadTest = Invoke-LatencyUnderLoadTest -Target '1.1.1.1' -Bytes $LoadBytes -Skip:$NoLoad -RateLimitMbps $LoadRateLimitMbps
Save-JsonSafe -Name 'latency_under_load' -Object $loadTest -Depth 7 | Out-Null
if ($loadTest.Attempted) {
    Add-Report 'Latency-under-load test:'
    foreach ($n in $loadTest.Notes) { Add-Report ('  ' + $n) }
    if ($loadTest.PingResult) { Add-Report (($loadTest.PingResult | Format-List * | Out-String -Width 240)) }
    Add-Report ('  BaselineAvgMs: {0}; LoadedP95Ms: {1}; LoadedP99Ms: {2}; LatencyIncreaseMs: {3}; DownloadMbps: {4}; ThroughputIsLineSpeed: {5}; Method: {6}' -f $loadTest.BaselineAvgMs, $loadTest.LoadedP95Ms, $loadTest.LoadedP99Ms, $loadTest.LatencyIncreaseMs, $loadTest.DownloadMbps, $loadTest.ThroughputIsLineSpeed, $loadTest.LoadMethod)
    Add-Report ''
}

$adapterStatsAfter = @(Get-AdapterStatsSnapshot -Name 'after')
$adapterDelta = @(Compare-AdapterStats -Before $adapterStatsBefore -After $adapterStatsAfter)
if ($adapterStatsAfter.Count -gt 0) { $adapterStatsAfter | Export-Csv -LiteralPath (Join-Path $runDir 'adapter_statistics_after.csv') -NoTypeInformation -Encoding UTF8; Save-JsonSafe -Name 'adapter_statistics_after' -Object $adapterStatsAfter -Depth 6 | Out-Null }
if ($adapterDelta.Count -gt 0) { $adapterDelta | Export-Csv -LiteralPath (Join-Path $runDir 'adapter_statistics_delta.csv') -NoTypeInformation -Encoding UTF8; Save-JsonSafe -Name 'adapter_statistics_delta' -Object $adapterDelta -Depth 6 | Out-Null }
Invoke-LoggedCommand -Name 'netstat_e_after' -Command 'netstat.exe' -Arguments @('-e') -TimeoutSec 45 | Out-Null
Invoke-LoggedCommand -Name 'netstat_s_after' -Command 'netstat.exe' -Arguments @('-s') -TimeoutSec 45 | Out-Null
if (Get-Command Get-NetAdapterStatistics -ErrorAction SilentlyContinue) {
    Save-TextBlock -Name 'Get-NetAdapterStatistics_after' -ScriptBlock { Get-NetAdapterStatistics | Format-List * } | Out-Null
}

Set-NldProgress 'stopping_packet_capture'
Write-ConsoleLine 'Stopping Pktmon and exporting counters/traces...'
$pktmonState = Stop-PktmonSession -State $pktmonState
Save-JsonSafe -Name 'pktmon_state_final' -Object $pktmonState -Depth 7 | Out-Null
Add-Report 'Pktmon:'
foreach ($n in $pktmonState.Notes) { Add-Report ('  ' + $n) }
Add-Report ('  Directory: {0}' -f $pktmonDir)
Add-Report ''
Add-Summary 'Pktmon:'
foreach ($n in $pktmonState.Notes) { Add-Summary ('  ' + $n) }
Add-Summary ''

if ($runPathping) {
    Set-NldProgress 'running_route_path_tests'
    Write-ConsoleLine 'Running route/path tests...'
    Invoke-LoggedCommand -Name 'tracert_1.1.1.1' -Command 'tracert.exe' -Arguments @('-d','-4','1.1.1.1') -TimeoutSec 120 | Out-Null
    Invoke-LoggedCommand -Name 'tracert_8.8.8.8' -Command 'tracert.exe' -Arguments @('-d','-4','8.8.8.8') -TimeoutSec 120 | Out-Null
    Invoke-LoggedCommand -Name 'pathping_1.1.1.1' -Command 'pathping.exe' -Arguments @('-n','-4','-q',([string]$pathpingQueries),'-p','100','-w','1000','1.1.1.1') -TimeoutSec 240 | Out-Null
}

$netshTraceState = Stop-NetshTraceSession -State $netshTraceState
Save-JsonSafe -Name 'netsh_trace_state_final' -Object $netshTraceState -Depth 7 | Out-Null
if ($netshTraceState -and ($netshTraceState.Attempted -or $NetshTrace)) {
    Add-Report 'netsh trace:'
    foreach ($n in $netshTraceState.Notes) { Add-Report ('  ' + $n) }
    Add-Report ('  Directory: {0}' -f $netshTraceDir)
    Add-Report ''
}
} finally {
    try { $pktmonState = Stop-PktmonSession -State $pktmonState } catch {}
    try { $netshTraceState = Stop-NetshTraceSession -State $netshTraceState } catch {}
}

Set-NldProgress 'probing_modem_pages'
Write-ConsoleLine 'Trying common cable-modem status pages...'
$modemPages = Get-ModemPages -DefaultGateway $defaultGateway
Save-JsonSafe -Name 'modem_pages' -Object $modemPages -Depth 5 | Out-Null
$modemAnalysis = Analyze-ModemText -ExtractedFile $modemPages.ExtractedFile -ModemPages $modemPages
Save-JsonSafe -Name 'modem_analysis' -Object $modemAnalysis -Depth 6 | Out-Null

Add-Report 'Cable modem status-page collection:'
Add-Report ('  Pages tried: {0}' -f $modemPages.PagesTried)
Add-Report ('  Pages saved: {0}' -f $modemPages.PagesSaved)
if ($modemPages.AccessibleUrls.Count -gt 0) { Add-Report ('  Accessible URL(s): {0}' -f ($modemPages.AccessibleUrls -join ', ')) }
if ($modemPages.DetectedModem) { Add-Report ('  Detected modem page: {0}' -f $modemPages.DetectedModem) }
if ($modemPages.LoginDetected) { Add-Report '  Login page detected; modem password was not collected.' }
if ($modemPages.Notes.Count -gt 0) { foreach ($n in $modemPages.Notes) { Add-Report ('  ' + $n) } }
Add-Report ('  Extracted modem status lines: {0}' -f $modemPages.ExtractedFile)
if ($modemAnalysis.Notes.Count -gt 0) { foreach ($n in $modemAnalysis.Notes) { Add-Report ('  ' + $n) } }
Add-Report ''

$recommendations = @(New-Recommendations -PingResults $pingResults -WifiInfo $wifiInfo -ModemAnalysis $modemAnalysis -AdapterDelta $adapterDelta -MtuResults $mtuResults -LoadTest $loadTest -PktmonState $pktmonState)
$advancedRecommendations = @(New-AdvancedRecommendations -PingResults $pingResults -FirstHopProbe $firstHopProbe -TcpResults $tcpResults -DnsTimingResults $dnsTimingResults -EventAnalysis $eventAnalysis -AdapterDriverAnalysis $adapterDriverAnalysis -NetshTraceState $netshTraceState)
$networkStackRecommendations = @(New-NetworkStackRecommendations -Stack $networkStackHealth)
$recommendations = @($recommendations + $advancedRecommendations + $networkStackRecommendations | Select-Object -Unique)

$scorecardPath = Join-Path $runDir 'DIAGNOSTIC_SCORECARD.txt'
$scorecardLines = @(New-DiagnosticScorecard -PingResults $pingResults -FirstHopProbe $firstHopProbe -TcpResults $tcpResults -ModemAnalysis $modemAnalysis -AdapterDelta $adapterDelta -EventAnalysis $eventAnalysis -AdapterDriverAnalysis $adapterDriverAnalysis -PktmonState $pktmonState -NetshTraceState $netshTraceState -LoadTest $loadTest)
if ($networkStackHealth) {
    $scorecardLines += ''
    $scorecardLines += ('Windows network-stack context: active adapters={0}; VPN/virtual-like={1}; enabled third-party/filter-like bindings={2}' -f $networkStackHealth.ActiveAdapterCount,$networkStackHealth.ActiveVpnOrVirtualAdapterCount,$networkStackHealth.EnabledThirdPartyOrFilterBindingCount)
    $scorecardLines += ('Default routes: IPv4={0}; IPv6={1}; multiple active route paths={2}' -f $networkStackHealth.IPv4DefaultRouteCount,$networkStackHealth.IPv6DefaultRouteCount,$networkStackHealth.MultipleActiveDefaultRoutes)
    $scorecardLines += ('NCSI: profile Internet={0}; DNS probe={1}; HTTP probe={2}; mismatch={3}' -f $networkStackHealth.Ncsi.ProfileReportsInternet,$networkStackHealth.Ncsi.DnsProbe.Success,$networkStackHealth.Ncsi.HttpProbe.Success,$networkStackHealth.Ncsi.MismatchDetected)
    $scorecardLines += ('Active-DNS DoH records: {0}; TCP auto-tuning: {1}' -f $networkStackHealth.ActiveDnsDohRecordCount,$networkStackHealth.TcpGlobal.AutoTuningLevel)
}
$scorecardLines | Set-Content -LiteralPath $scorecardPath -Encoding UTF8
Save-JsonSafe -Name 'diagnostic_scorecard_lines' -Object $scorecardLines -Depth 5 | Out-Null
Add-Report 'Diagnostic scorecard:'
foreach ($line in $scorecardLines) { Add-Report ('  ' + $line) }
Add-Report ''

'Suggested fixes / next tests' | Set-Content -LiteralPath $suggestionsPath -Encoding UTF8
'============================' | Out-File -FilePath $suggestionsPath -Append -Encoding UTF8
'' | Out-File -FilePath $suggestionsPath -Append -Encoding UTF8
for ($i=0; $i -lt $recommendations.Count; $i++) { ('{0}. {1}' -f ($i+1), $recommendations[$i]) | Out-File -FilePath $suggestionsPath -Append -Encoding UTF8 }

Add-Report 'Adapter counter deltas during test:'
if ($adapterDelta.Count -gt 0) { Add-Report (($adapterDelta | Format-Table -AutoSize Name,ReceivedDiscardedPackets_Delta,OutboundDiscardedPackets_Delta,ReceivedPacketErrors_Delta,OutboundPacketErrors_Delta | Out-String -Width 220)) } else { Add-Report '  No adapter delta data available.' }
Add-Report ''

Add-Report 'Suggested fixes / next tests:'
for ($i=0; $i -lt $recommendations.Count; $i++) { Add-Report ('  {0}. {1}' -f ($i+1), $recommendations[$i]) }
Add-Report ''

Add-Summary 'Suggested fixes / next tests:'
for ($i=0; $i -lt $recommendations.Count; $i++) { Add-Summary ('  {0}. {1}' -f ($i+1), $recommendations[$i]) }
Add-Summary ''
Add-Summary 'Review the compact support ZIP before sharing:'

$readmeOut = Join-Path $runDir 'HOW_TO_SHARE.txt'
@"
How to share this diagnostic

1. Review PRIVACY_NOTICE.txt and inspect every file in the ZIP.
2. Remove data that should not leave the computer.
3. Share only through an approved channel with a trusted support recipient.
4. Include the exact command, symptom time, and any changes made while the test ran.

The compact *_SUPPORT_EXPORT.zip is capped at 20 files and merges the most useful evidence:
- SUMMARY_REDACTED.txt
- DIAGNOSTIC_SCORECARD.txt
- SUGGESTED_FIXES.txt
- REPORT_CONCISE.txt
- packet_loss_tests.csv
- packet_loss_samples.csv, when collected
- NETWORK_SNAPSHOT_COMPACT.txt, including VPN/filter bindings, TCP/offload, DoH, and NCSI context
- MODEM_EVENTS_COMPACT.txt
- network_stack_health.json, when the 20-file priority budget permits
- ERRORS_AND_WARNINGS.txt
- AUTO_DIAG_PROGRAM_STATE.txt

The raw report folder remains local for deeper troubleshooting. Do not share device credentials or session data.
"@ | Set-Content -LiteralPath $readmeOut -Encoding UTF8

$finishedAt = Get-Date
$durationSeconds = $Script:RunStopwatch.Elapsed.TotalSeconds
Add-Report ('Finished: {0}' -f $finishedAt.ToString('o'))
Add-Report ('DurationMonotonic: {0:n1} seconds' -f $durationSeconds)
Add-Report ('LastProgressStage: {0}; LastProgressTime: {1}' -f $Script:CurrentStage,$Script:LastProgressTime.ToString('o'))
Add-Summary ('Finished: {0}' -f $finishedAt.ToString('o'))
Add-Summary ('DurationMonotonic: {0:n1} seconds' -f $durationSeconds)
Add-Summary ('LastProgressStage: {0}' -f $Script:CurrentStage)

$zipPath = Join-Path $baseDir ($runName + '_SUPPORT_EXPORT.zip')
if (-not $NoZip) {
    Add-Report ('Planned compact support export ZIP: {0}' -f $zipPath)
    Add-Summary $zipPath
    ('Export ZIP: ' + $zipPath) | Set-Content -LiteralPath (Join-Path $runDir 'ZIP_PATH.txt') -Encoding UTF8
}
New-RedactedSummary -Source $summaryPath -Destination $redactedSummaryPath

if (-not $NoZip) {
    Set-NldProgress 'creating_support_export'
    Write-ConsoleLine 'Creating compact support export ZIP...'
    try {
        $zipPath = Join-Path $baseDir ($runName + '_SUPPORT_EXPORT.zip')
        $zipResult = New-SupportZip -RunDir $runDir -ZipPath $zipPath -MaxFiles $ExportFileLimit
        Add-Report ('Compact export ZIP: {0}' -f $zipPath)
        Add-Report ('Compact export file count: {0}; limit: {1}' -f $zipResult.FileCount, $zipResult.MaxFiles)
        Add-Report ('Compact export integrity verified: {0}; SHA256: {1}' -f $zipResult.IntegrityVerified,$zipResult.ArchiveSha256)
        Add-Summary ('Compact export ZIP file count: {0}; limit: {1}' -f $zipResult.FileCount, $zipResult.MaxFiles)
        ('Export ZIP: ' + $zipPath) | Set-Content -LiteralPath (Join-Path $runDir 'ZIP_PATH.txt') -Encoding UTF8
    } catch {
        $primaryExportError = $_.Exception.Message
        Add-Report ('Could not create compact support ZIP: {0}' -f $primaryExportError)
        Add-Summary ('ZIP creation failed: {0}' -f $primaryExportError)
        New-RedactedSummary -Source $summaryPath -Destination $redactedSummaryPath
        $fallbackZip = Join-Path $baseDir ($runName + '_MINIMAL_ERROR_SUPPORT_EXPORT.zip')
        try {
            $fallbackResult = New-MinimalFallbackSupportZip -RunDir $runDir -ZipPath $fallbackZip -Reason $primaryExportError
            $zipPath = $fallbackZip
            Add-Report ('Minimal fallback export ZIP: {0}; file count: {1}' -f $fallbackZip,$fallbackResult.FileCount)
            Add-Summary ('Minimal fallback export ZIP created: {0}' -f $fallbackZip)
        } catch {
            Add-Report ('Minimal fallback ZIP also failed: {0}' -f $_.Exception.Message)
            Add-Summary ('Minimal fallback ZIP also failed: {0}' -f $_.Exception.Message)
            $zipPath = $null
        }
    }
}

Set-NldProgress 'complete'
Write-ConsoleLine ''
Write-ConsoleLine 'Done.'
Write-ConsoleLine ('Report folder: {0}' -f $runDir)
if ($zipPath) { Write-ConsoleLine ('Export ZIP: {0}' -f $zipPath) }
Write-ConsoleLine ''
Write-ConsoleLine 'Review the compact support ZIP before sharing it with a trusted support recipient.'
exit 0
