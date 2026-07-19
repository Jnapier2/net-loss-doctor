# NetLossDoctor

NetLossDoctor is a transparent Windows PowerShell diagnostic that turns packet-loss complaints into a structured, time-bounded evidence bundle. It correlates local adapter state, routes, DNS, latency, Windows networking events, and optional deep traces without changing network configuration.

## Why it exists

Intermittent network problems are difficult to reproduce and easy to misdiagnose. A single ping cannot distinguish a local adapter problem from Wi-Fi interference, DNS failure, a router issue, or upstream loss. NetLossDoctor collects comparable evidence and produces a concise scorecard plus a redacted support archive.

Engineering highlights:

- Bounded command execution and cleanup for long-running Windows diagnostics.
- Correlated gateway, first-hop, public endpoint, DNS, TCP, MTU, and event-log evidence.
- Read-only inventories of adapter bindings, VPN-like routes, TCP/offload state, DoH, proxy, and NCSI state.
- Percentile latency and repeated-run comparison support.
- Fail-isolated collectors: unsupported or permission-limited checks do not invalidate the full run.
- Local redaction and compact export paths for safer support handoff.

## Safety model

Running `NetLossDoctor.ps1` with no arguments performs `doctor` mode, a local program/export self-test with no network probes. Active tests require an explicit `-Mode`.

The tool does not change adapters, bindings, routes, DNS, proxy, firewall, TCP/offload settings, VPN state, execution-policy scopes, or security software. It does not self-elevate.

Two deeper collectors are off by default:

- `-EnablePktmon` opts into Windows Packet Monitor counters/capture when the process is already elevated. The diagnostic skips collection when filters already exist, adds only two uniquely named filters, and removes those names in `finally` cleanup.
- `-NetshTrace` opts into a bounded `InternetClient` ETL trace when the process is already elevated. Pktmon and netsh capture lifecycles are both enclosed by outer `try/finally` cleanup.

`full` mode can also download a bounded test payload for latency-under-load analysis. This network traffic is never part of the default invocation, can be disabled with `-NoLoad`, and can be rate-limited with `-LoadRateLimitMbps`. Its throughput is context, not a certified line-speed measurement.

The program never changes clipboard contents.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or later
- A writable project folder

No package installation is required. Review the source and use your organization's approved PowerShell policy; the repository does not bypass policy controls.

## Quick start

```powershell
# Local self-test; no network probes
powershell.exe -NoProfile -File .\NetLossDoctor.ps1

# Preview a baseline without collecting it
powershell.exe -NoProfile -File .\NetLossDoctor.ps1 -Mode standard -DryRun

# Short active baseline
powershell.exe -NoProfile -File .\NetLossDoctor.ps1 -Mode quick

# Normal active baseline
powershell.exe -NoProfile -File .\NetLossDoctor.ps1 -Mode standard
```

Use `Start-NetLossDoctor.cmd` as a convenience wrapper; with no arguments it retains the safe `doctor` default.

### Modes and explicit options

| Command | Network activity | Administrator needed | Purpose |
| --- | --- | --- | --- |
| no arguments / `-Mode doctor` | None | No | Program and export self-test |
| `-Mode quick` | Short probes | No | Fast baseline |
| `-Mode standard` | Active probes | No | Normal evidence collection |
| `-Mode observe` | Repeated probes | No | Intermittent-loss watch |
| `-Mode appcheck` | DNS/TCP/HTTP probes | No | Application-connectivity triage |
| `-Mode full -NoLoad` | Broad probes | No | Broad diagnosis without load download |
| `-Mode full` | Broad probes + bounded download | No | Latency-under-load analysis |
| `-EnablePktmon` | Packet counters/capture | Yes | Optional local drop evidence |
| `-NetshTrace` | ETL network trace | Yes | Optional deep Windows trace |

Reports are written beneath `exports/NetLossDoctor_Reports` by default. Use `-ReportsRoot` to select a different writable location.

Compare recent result bundles with:

```powershell
powershell.exe -NoProfile -File .\Compare-NetLossDoctorReports.ps1 -ReportsPath .\exports\NetLossDoctor_Reports
```

## Data collected

Depending on mode and Windows permissions, a report may include the computer and user names, OS version, local IP and MAC addresses, gateways, DNS servers, adapter and driver names, routes, Wi-Fi SSID/radio/channel/signal, nearby SSIDs, connection profile, proxy/NCSI state, selected Windows event messages, and probe results. Optional captures can contain substantially more network metadata.

Treat all generated reports as sensitive operational data. The compact export applies redaction, but review every artifact before sharing. Generated outputs are excluded by `.gitignore`.

The file in `examples/` is synthetic and contains no real host or network information.

## Validation

```powershell
powershell.exe -NoProfile -File .\tests\Test-PublicSafety.ps1
```

CI parses every PowerShell file, exercises synthetic redaction cases, mocks capture cleanup, and enforces the public safety invariants: local self-test is the default, captures are opt-in and bounded by `finally`, clipboard and execution-policy changes are absent, and common system-mutating networking cmdlets are not present.

## Project status

This portfolio release is a Windows-focused diagnostic and has not been independently security audited. Network equipment can suppress or deprioritize ICMP, so intermediate-hop loss alone is not proof of an outage. The tool provides evidence for analysis; it does not replace vendor or ISP instrumentation.

Copyright (c) 2026 Gateway Information Group LLC. See [LICENSE.md](LICENSE.md).
