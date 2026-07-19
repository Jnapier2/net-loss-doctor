# NetLossDoctor v2.10.0 report comparison helper.

param(
    [string]$ReportsPath = '',
    [int]$Days = 45
)
$Script:Version = '2.10.0'
$ErrorActionPreference = 'Continue'
function New-SafeName([string]$s){ if([string]::IsNullOrWhiteSpace($s)){return 'unknown'}; $x=($s -replace '[^a-zA-Z0-9_.-]+','_').Trim('_'); if($x){$x}else{'unknown'} }
if ([string]::IsNullOrWhiteSpace($ReportsPath)) {
    $toolRoot = $env:NLD_HOME
    if ([string]::IsNullOrWhiteSpace($toolRoot) -or -not (Test-Path -LiteralPath $toolRoot)) { $toolRoot = $PSScriptRoot }
    if ([string]::IsNullOrWhiteSpace($toolRoot)) { $toolRoot = (Get-Location).Path }
    $ReportsPath = Join-Path (Join-Path $toolRoot 'exports') 'NetLossDoctor_Reports'
}
if (-not (Test-Path -LiteralPath $ReportsPath)) { New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outTxt = Join-Path $ReportsPath ('NetLossDoctor_Comparison_' + $stamp + '.txt')
$outCsv = Join-Path $ReportsPath ('NetLossDoctor_Comparison_' + $stamp + '.csv')
$cutoff=(Get-Date).AddDays(-1*[Math]::Max(1,$Days))
$sources=@()
$sources += Get-ChildItem -LiteralPath $ReportsPath -Filter 'NetLossDoctor_*.zip' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoff }
$sources += Get-ChildItem -LiteralPath $ReportsPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^NetLossDoctor_' -and $_.LastWriteTime -ge $cutoff }
$temp = Join-Path $ReportsPath ('_compare_temp_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp -Force | Out-Null
trap {
    try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    Write-Error ('Comparison failed: ' + $_.Exception.Message)
    exit 1
}
$records=@()
foreach($src in ($sources | Sort-Object LastWriteTime)){
    $folder=$null
    try{
        if($src.PSIsContainer){ $folder=$src.FullName }
        else{
            $folder=Join-Path $temp (New-SafeName $src.BaseName)
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Expand-Archive -LiteralPath $src.FullName -DestinationPath $folder -Force -ErrorAction Stop
        }
        $csv=Get-ChildItem -LiteralPath $folder -Filter 'packet_loss_tests.csv' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if(-not $csv){ continue }
        $rows=@(Import-Csv -LiteralPath $csv.FullName -ErrorAction SilentlyContinue)
        $gw=$rows | Where-Object { $_.Label -eq 'Default gateway' } | Select-Object -First 1
        $ext=@($rows | Where-Object { $_.Label -match '^Internet IP' })
        $dns=@($rows | Where-Object { $_.Label -match '^DNS hostname|^DNS server' })
        $firstHop=$rows | Where-Object { $_.Label -match 'First ISP|CMTS|public|hop' } | Select-Object -First 1
        $sent=0;$lost=0;$maxLoss=0;$maxMax=0;$maxP95=0;$maxP99=0
        foreach($r in $ext){
            $sent += [int]$r.Sent; $lost += [int]$r.Lost
            $lp=[double]$r.LossPct; if($lp -gt $maxLoss){$maxLoss=$lp}
            if($r.MaxMs -ne ''){$mm=[double]$r.MaxMs; if($mm -gt $maxMax){$maxMax=$mm}}
            if($r.P95Ms -ne ''){$p95=[double]$r.P95Ms; if($p95 -gt $maxP95){$maxP95=$p95}}
            if($r.P99Ms -ne ''){$p99=[double]$r.P99Ms; if($p99 -gt $maxP99){$maxP99=$p99}}
        }
        $sysFile=Get-ChildItem -LiteralPath $folder -Filter 'system_summary.json' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $sys=$null; if($sysFile){ try{$sys=Get-Content -LiteralPath $sysFile.FullName -Raw | ConvertFrom-Json}catch{} }
        $loadFile=Get-ChildItem -LiteralPath $folder -Filter 'latency_under_load.json' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $load=$null; if($loadFile){ try{$load=Get-Content -LiteralPath $loadFile.FullName -Raw | ConvertFrom-Json}catch{} }
        $score=Get-ChildItem -LiteralPath $folder -Filter 'DIAGNOSTIC_SCORECARD.txt' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $drop=Get-ChildItem -LiteralPath $folder -Filter 'pktmon_counters_drops.txt' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        $dropStatus=''; if($drop){$dt=Get-Content -LiteralPath $drop.FullName -Raw -ErrorAction SilentlyContinue; if($dt -match '(?i)All counters are zero'){$dropStatus='zero'}elseif($dt){$dropStatus='review'}}
        $fhLoss = $(if($firstHop -and $firstHop.LossPct -ne ''){[double]$firstHop.LossPct}else{$null})
        $fhNote = ''
        if($firstHop -and $sent -gt 0 -and $lost -eq 0 -and $fhLoss -ge 50){ $fhNote = 'intermediate-hop ICMP ignore likely; downstream clean' }
        $records += [PSCustomObject]@{
            Report=$src.Name; Source='<LOCAL_PATH_REDACTED>'; LastWriteTime=$src.LastWriteTime.ToString('o')
            Started=$(if($sys -and $sys.Started){$sys.Started}else{''}); Version=$(if($sys -and $sys.Version){$sys.Version}else{''}); Mode=$(if($sys -and $sys.Mode){$sys.Mode}else{''}); Label=$(if($sys -and $sys.Label){$sys.Label}else{''})
            LoadRateLimitMbps=$(if($sys -and $sys.LoadRateLimitMbps -ne $null){[double]$sys.LoadRateLimitMbps}elseif($load -and $load.LoadRateLimitMbps -ne $null){[double]$load.LoadRateLimitMbps}else{0})
            GatewayLossPct=$(if($gw){[double]$gw.LossPct}else{$null}); GatewayMaxMs=$(if($gw -and $gw.MaxMs -ne ''){[double]$gw.MaxMs}else{$null})
            ExternalSent=$sent; ExternalLost=$lost; ExternalLossPct=$(if($sent -gt 0){[math]::Round(100.0*$lost/$sent,2)}else{$null}); MaxSingleExternalLossPct=$maxLoss; MaxExternalMaxMs=$maxMax; MaxExternalP95Ms=$maxP95; MaxExternalP99Ms=$maxP99
            DnsLossTotal=(@($dns | ForEach-Object {[int]$_.Lost}) | Measure-Object -Sum).Sum
            FirstHopLossPct=$fhLoss; FirstHopNote=$fhNote
            LoadAttempted=$(if($load -and $load.Attempted){[bool]$load.Attempted}else{$false}); LoadDownloadMbps=$(if($load -and $load.DownloadMbps -ne $null){[double]$load.DownloadMbps}else{$null}); LoadLatencyIncreaseMs=$(if($load -and $load.LatencyIncreaseMs -ne $null){[double]$load.LatencyIncreaseMs}else{$null}); LoadThroughputIsLineSpeed=$(if($load -and $load.ThroughputIsLineSpeed -ne $null){[bool]$load.ThroughputIsLineSpeed}else{$null})
            PktmonDrops=$dropStatus; HasScorecard=[bool]$score
        }
    }catch{}
}
if($records.Count -gt 0){ $records | Export-Csv -LiteralPath $outCsv -NoTypeInformation -Encoding UTF8 }
$lines=New-Object System.Collections.Generic.List[string]
$lines.Add(('NetLossDoctor comparison helper v' + $Script:Version))|Out-Null
$lines.Add('NetLossDoctor repeated-run comparison')|Out-Null
$lines.Add('Created: '+(Get-Date).ToString('o'))|Out-Null
$lines.Add('Reports path: <REPORTS_PATH_REDACTED>')|Out-Null
$lines.Add('Window: last '+$Days+' days')|Out-Null
$lines.Add('')|Out-Null
if($records.Count -eq 0){ $lines.Add('No reports with packet_loss_tests.csv were found.')|Out-Null }
else{
    $lines.Add(($records | Sort-Object LastWriteTime | Format-Table -AutoSize Report,Version,Mode,Label,LoadRateLimitMbps,GatewayLossPct,ExternalLost,ExternalSent,ExternalLossPct,MaxExternalP95Ms,MaxExternalP99Ms,LoadLatencyIncreaseMs,PktmonDrops | Out-String -Width 360))|Out-Null
    $clean=$records | Where-Object {$_.ExternalSent -gt 0} | Sort-Object ExternalLossPct,GatewayLossPct,MaxExternalP95Ms | Select-Object -First 1
    $bad=$records | Where-Object {$_.ExternalSent -gt 0} | Sort-Object -Property @{Expression='ExternalLossPct';Descending=$true}, @{Expression='MaxExternalP95Ms';Descending=$true} | Select-Object -First 1
    if($clean){$lines.Add(('Cleanest external run: {0} = {1}% external loss, max external p95 {2} ms.' -f $clean.Report,$clean.ExternalLossPct,$clean.MaxExternalP95Ms))|Out-Null}
    if($bad){$lines.Add(('Worst external run: {0} = {1}% external loss, max external p95 {2} ms.' -f $bad.Report,$bad.ExternalLossPct,$bad.MaxExternalP95Ms))|Out-Null}
    $nearClean=@($records | Where-Object {$_.ExternalSent -ge 1000 -and $_.ExternalLossPct -le 0.10 -and ($_.GatewayLossPct -eq 0 -or $_.GatewayLossPct -eq $null)})
    if($nearClean.Count -gt 0){$lines.Add(('Near-clean note: {0} long run(s) had <=0.10% external loss with a clean gateway. Treat those as stable unless they match visible symptoms.' -f $nearClean.Count))|Out-Null}
    $gwBad=@($records | Where-Object {$_.GatewayLossPct -ge 1})
    if($gwBad.Count -gt 0){$lines.Add('At least one run had gateway loss. That points to local LAN/router/NIC/switch/cable issues for that run, not just coax/ISP.')|Out-Null}
    $extBadGwClean=@($records | Where-Object {$_.ExternalLossPct -ge 1 -and ($_.GatewayLossPct -eq 0 -or $_.GatewayLossPct -eq $null)})
    if($extBadGwClean.Count -gt 0){$lines.Add('At least one run had external loss while the gateway was clean. Correlate router-WAN, modem, physical-link, and provider evidence before assigning cause.')|Out-Null}
    $loadBad=@($records | Where-Object {$_.LoadAttempted -and $_.LoadLatencyIncreaseMs -ne $null -and $_.LoadLatencyIncreaseMs -gt 100})
    if($loadBad.Count -gt 0){$lines.Add('At least one full-mode load test showed a large latency increase. Treat bounded-transfer throughput as context and focus on loaded latency, loss, and queueing.')|Out-Null}
}
$lines | Set-Content -LiteralPath $outTxt -Encoding UTF8
Write-Host 'Comparison complete.'
Write-Host ('Text: '+$outTxt)
if(Test-Path -LiteralPath $outCsv){Write-Host ('CSV:  '+$outCsv)}
try{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}catch{}
