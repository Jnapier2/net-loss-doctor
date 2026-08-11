from __future__ import annotations

import json
from pathlib import Path

ROOT = Path.cwd()
RIGHTS = "Copyright © 2026 Gateway Information Group LLC. All rights reserved."
BUILD_ID = "NLD-2.10.0-PUBLIC-20260810-01"
PARAMETER_SHA256 = "5dd39656afa5e8bcd0159e5ffa163d4de92a9ad4cb05c26aa63acf424ffe371f"
TEMP_PATHS = {
    ".github/scripts/apply_project_local_output_hardening.py",
    ".github/workflows/apply_project_local_output_hardening.yml",
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def write_text(path: Path, text: str) -> None:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    newline = "\r\n" if path.suffix.lower() in {".ps1", ".cmd", ".bat"} else "\n"
    path.write_text(normalized, encoding="utf-8", newline=newline)


def replace_required(path: Path, old: str, new: str, *, count: int = 1) -> None:
    text = read_text(path)
    occurrences = text.count(old)
    if occurrences < count:
        raise SystemExit(
            f"Expected at least {count} occurrence(s) in {path}, found {occurrences}: {old!r}"
        )
    write_text(path, text.replace(old, new, count))


def patch_engine() -> None:
    path = ROOT / "NetLossDoctor.ps1"
    text = read_text(path)

    replacements = [
        (
            "$Script:Version = '2.10.0'\n",
            "$Script:Version = '2.10.0'\n$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-01'\n$Script:ParameterBaseline = '2.17.6'\n",
        ),
        (
            "    if ([string]::IsNullOrWhiteSpace($dryToolRoot)) { $dryToolRoot = (Get-Location).Path }\n",
            "    if ([string]::IsNullOrWhiteSpace($dryToolRoot)) {\n        Write-Error 'Unable to resolve the NetLossDoctor project root from NLD_HOME or the script location. No output was created.'\n        exit 24\n    }\n",
        ),
        (
            "        New-Item -ItemType Directory -Path $Path -Force | Out-Null\n",
            "        New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null\n",
        ),
        (
            "            if ([string]::IsNullOrWhiteSpace($BasePath) -or -not (Test-Path -LiteralPath $BasePath)) { $BasePath = (Get-Location).Path }\n",
            "            if ([string]::IsNullOrWhiteSpace($BasePath) -or -not (Test-Path -LiteralPath $BasePath)) { return $null }\n",
        ),
        (
            "if ([string]::IsNullOrWhiteSpace($toolRoot) -or -not (Test-Path -LiteralPath $toolRoot)) {\n    $toolRoot = (Get-Location).Path\n    $Script:ToolRootResolutionNote = 'current_working_directory_fallback'\n}\n",
            "if ([string]::IsNullOrWhiteSpace($toolRoot) -or -not (Test-Path -LiteralPath $toolRoot)) {\n    Write-Error 'Unable to resolve the NetLossDoctor project root from NLD_HOME or the script location. No report directory was created.'\n    exit 24\n}\n",
        ),
        (
            "try {\n    New-DirectorySafe $baseDir\n} catch {\n    $desktop = [Environment]::GetFolderPath('Desktop')\n    if ([string]::IsNullOrWhiteSpace($desktop)) { $desktop = $env:TEMP }\n    $baseDir = Join-Path $desktop 'NetLossDoctor_Reports'\n    try { New-DirectorySafe $baseDir } catch {\n        $baseDir = Join-Path $env:TEMP 'NetLossDoctor_Reports'\n        New-DirectorySafe $baseDir\n    }\n}\n",
            "try {\n    New-DirectorySafe $baseDir\n} catch {\n    Write-Error (\"Unable to create the selected report root '{0}'. No Desktop or OS-temp fallback will be used. {1}\" -f $baseDir, $_.Exception.Message)\n    exit 25\n}\n",
        ),
    ]

    for old, new in replacements:
        if text.count(old) != 1:
            raise SystemExit(
                f"Expected exactly one engine marker, found {text.count(old)}: {old!r}"
            )
        text = text.replace(old, new, 1)

    forbidden = [
        "current_working_directory_fallback",
        "$baseDir = Join-Path $desktop 'NetLossDoctor_Reports'",
        "$baseDir = Join-Path $env:TEMP 'NetLossDoctor_Reports'",
    ]
    for marker in forbidden:
        if marker in text:
            raise SystemExit(f"Retired output-authority marker remains: {marker}")

    write_text(path, text)


def patch_readme() -> None:
    path = ROOT / "README.md"
    text = read_text(path)
    old_launcher = (
        "Use `Start-NetLossDoctor.cmd` as a convenience wrapper; with no arguments it retains "
        "the safe `doctor` default."
    )
    new_launcher = (
        "Use `Start-NetLossDoctor.cmd` as the stable, project-qualified canonical entrypoint. "
        "It launches `NetLossDoctor.ps1` from the wrapper's own directory and retains the safe "
        "`doctor` default when no arguments are supplied."
    )
    old_reports = (
        "Reports are written beneath `exports/NetLossDoctor_Reports` by default. Use "
        "`-ReportsRoot` to select a different writable location."
    )
    new_reports = (
        "Reports are written beneath `exports/NetLossDoctor_Reports` under the resolved project "
        "folder by default. Relative `-ReportsRoot` values are rebased from that project folder; "
        "an absolute override remains an explicit user-selected external binding. If the selected "
        "location cannot be created, the run fails closed instead of writing final output to the "
        "caller working directory, Desktop, or operating-system temporary storage."
    )
    old_validation = (
        "CI parses every PowerShell file, exercises synthetic redaction cases, mocks capture cleanup, "
        "and enforces the safety invariants: local self-test is the default, captures are opt-in and "
        "bounded by `finally`, clipboard and execution-policy changes are absent, and common "
        "system-mutating networking cmdlets are not present."
    )
    new_validation = (
        "CI parses every PowerShell file, exercises synthetic redaction cases, mocks capture cleanup, "
        "launches the dry-run path from an unrelated working directory, and enforces the safety "
        "invariants: local self-test is the default, captures are opt-in and bounded by `finally`, "
        "project-root resolution is launcher/script-derived, final outputs stay project-local unless "
        "the user explicitly selects an external root, clipboard and execution-policy changes are "
        "absent, and common system-mutating networking cmdlets are not present."
    )
    for old, new in (
        (old_launcher, new_launcher),
        (old_reports, new_reports),
        (old_validation, new_validation),
    ):
        if text.count(old) != 1:
            raise SystemExit(f"Expected exactly one README marker, found {text.count(old)}: {old!r}")
        text = text.replace(old, new, 1)

    metadata_note = (
        "\n`PUBLIC_SOURCE_METADATA.json` records the public source build, canonical entrypoint, "
        "backend target, project-local output roots, explicit external-output boundary, and the "
        "remaining runtime-identity limitation without representing this source-only v2.10.0 tree "
        "as a sealed executable package.\n"
    )
    status_marker = "\n## Project status\n"
    if metadata_note.strip() not in text:
        if status_marker not in text:
            raise SystemExit("README project-status marker was not found")
        text = text.replace(status_marker, metadata_note + status_marker, 1)
    write_text(path, text)


def create_public_metadata() -> None:
    path = ROOT / "PUBLIC_SOURCE_METADATA.json"
    metadata = {
        "schema": "NetLossDoctor.public_source_metadata.v1",
        "project": "NetLossDoctor",
        "project_slug": "net-loss-doctor",
        "version": "2.10.0",
        "build_id": BUILD_ID,
        "status": "current-public-source",
        "parameter_baseline": "2.17.6",
        "parameter_package_sha256": PARAMETER_SHA256,
        "canonical_entrypoint": "Start-NetLossDoctor.cmd",
        "backend_target": "NetLossDoctor.ps1",
        "project_root_resolution": "validated NLD_HOME override or launcher/script location; caller CWD is not authority",
        "runtime_owned_output_roots": ["exports/NetLossDoctor_Reports"],
        "external_output_binding": "absolute -ReportsRoot supplied explicitly by the user",
        "output_failure_policy": "fail_closed_no_cwd_desktop_or_os_temp_final_output_fallback",
        "runtime_identity_gate": {
            "status": "not_implemented_in_public_v2.10.0_source",
            "claim_boundary": "This metadata file does not substitute for VERSION.txt, MANIFEST.json, PACKAGE_METADATA.json, or managed-file startup verification."
        },
        "behavior_change": "project-root and final-output containment hardening only",
        "network_configuration_changes": False,
        "elevation_required": False,
        "rights_holder": "Gateway Information Group LLC",
        "rights_notice": RIGHTS,
        "third_party_notice": "Windows and PowerShell remain subject to their respective terms."
    }
    write_text(path, json.dumps(metadata, indent=2, ensure_ascii=False) + "\n")


def patch_tests() -> None:
    path = ROOT / "tests/Test-SafetyContracts.ps1"
    text = read_text(path)

    old_header = (
        "$enginePath = Join-Path $repo 'NetLossDoctor.ps1'\n"
        "$comparePath = Join-Path $repo 'Compare-NetLossDoctorReports.ps1'\n"
        "$engine = Get-Content -LiteralPath $enginePath -Raw\n"
        "$compare = Get-Content -LiteralPath $comparePath -Raw\n"
    )
    new_header = old_header + (
        "$metadataPath = Join-Path $repo 'PUBLIC_SOURCE_METADATA.json'\n"
        "Assert-True (Test-Path -LiteralPath $metadataPath -PathType Leaf) 'Public source metadata is missing.'\n"
        "$publicMetadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json\n"
        "Assert-True ($publicMetadata.build_id -eq 'NLD-2.10.0-PUBLIC-20260810-01') 'Public source build ID changed.'\n"
        "Assert-True ($publicMetadata.canonical_entrypoint -eq 'Start-NetLossDoctor.cmd') 'Canonical entrypoint metadata changed.'\n"
        "Assert-True ($publicMetadata.backend_target -eq 'NetLossDoctor.ps1') 'Backend-target metadata changed.'\n"
        "Assert-True (@($publicMetadata.runtime_owned_output_roots) -contains 'exports/NetLossDoctor_Reports') 'Project-local output metadata changed.'\n"
        "Assert-True ($publicMetadata.output_failure_policy -eq 'fail_closed_no_cwd_desktop_or_os_temp_final_output_fallback') 'Output failure policy changed.'\n"
        "Assert-True ($publicMetadata.runtime_identity_gate.status -eq 'not_implemented_in_public_v2.10.0_source') 'Runtime identity claim boundary changed.'\n"
    )
    if text.count(old_header) != 1:
        raise SystemExit("Test header marker did not match exactly once")
    text = text.replace(old_header, new_header, 1)

    static_anchor = (
        "Assert-True ($engine -match 'EXPORT_CONTENTS\\.txt') 'Support archives must retain a plain-language contents file.'\n"
    )
    static_assertions = static_anchor + (
        "Assert-True ($engine -match \"\\$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-01'\") 'Transparent public build ID is missing.'\n"
        "Assert-True ($engine -notmatch 'current_working_directory_fallback') 'Caller CWD must not be project-root authority.'\n"
        "Assert-True ($engine -notmatch \"\\$baseDir = Join-Path \\$desktop 'NetLossDoctor_Reports'\") 'Desktop must not be a final-output fallback.'\n"
        "Assert-True ($engine -notmatch \"\\$baseDir = Join-Path \\$env:TEMP 'NetLossDoctor_Reports'\") 'OS temp must not be a final-output fallback.'\n"
        "Assert-True ($engine -match 'No Desktop or OS-temp fallback will be used') 'Fail-closed output error is missing.'\n"
        "Assert-True ($engine -match 'New-Item -ItemType Directory -Path \\$Path -Force -ErrorAction Stop') 'Directory creation must be terminating so fail-closed handling can run.'\n"
    )
    if text.count(static_anchor) != 1:
        raise SystemExit("Static assertion anchor did not match exactly once")
    text = text.replace(static_anchor, static_assertions, 1)

    footer = (
        "Write-Host (\"PASS: parsed {0} PowerShell files and verified safety invariants.\" -f $powerShellFiles.Count) -ForegroundColor Green\n"
    )
    cross_cwd = (
        "$crossCwd = Join-Path ([IO.Path]::GetTempPath()) ('NetLossDoctor_CrossCwd_' + [guid]::NewGuid().ToString('N'))\n"
        "$oldLocation = Get-Location\n"
        "$oldNldHome = $env:NLD_HOME\n"
        "try {\n"
        "    New-Item -ItemType Directory -Path $crossCwd -Force | Out-Null\n"
        "    $env:NLD_HOME = Join-Path $crossCwd 'stale-home'\n"
        "    Set-Location -LiteralPath $crossCwd\n"
        "    $dryOutput = (& powershell.exe -NoLogo -NoProfile -File $enginePath -Mode standard -DryRun 2>&1 | Out-String)\n"
        "    $dryExit = $LASTEXITCODE\n"
        "    Assert-True ($dryExit -eq 0) (\"Cross-working-directory dry run failed with exit code {0}: {1}\" -f $dryExit, $dryOutput)\n"
        "    $expectedRoot = [IO.Path]::GetFullPath($repo)\n"
        "    $expectedReports = Join-Path (Join-Path $expectedRoot 'exports') 'NetLossDoctor_Reports'\n"
        "    Assert-True ($dryOutput -match [Regex]::Escape(\"Tool root resolved: $expectedRoot\")) 'Dry run did not resolve the tool root from the script location.'\n"
        "    Assert-True ($dryOutput -match [Regex]::Escape(\"ReportsRoot resolved: $expectedReports\")) 'Dry run did not keep the default report root under the project folder.'\n"
        "    Assert-True (-not (Test-Path -LiteralPath (Join-Path $crossCwd 'exports'))) 'Caller CWD received an unexpected output directory.'\n"
        "} finally {\n"
        "    Set-Location -LiteralPath $oldLocation.Path\n"
        "    $env:NLD_HOME = $oldNldHome\n"
        "    Remove-Item -LiteralPath $crossCwd -Recurse -Force -ErrorAction SilentlyContinue\n"
        "}\n\n"
        + footer
    )
    if text.count(footer) != 1:
        raise SystemExit("Test footer marker did not match exactly once")
    text = text.replace(footer, cross_cwd, 1)
    write_text(path, text)


def main() -> int:
    patch_engine()
    patch_readme()
    create_public_metadata()
    patch_tests()
    print(json.dumps({
        "project": "NetLossDoctor",
        "version": "2.10.0",
        "build_id": BUILD_ID,
        "canonical_entrypoint": "Start-NetLossDoctor.cmd",
        "backend_target": "NetLossDoctor.ps1",
        "default_output_root": "exports/NetLossDoctor_Reports",
        "output_failure_policy": "fail_closed_no_cwd_desktop_or_os_temp_final_output_fallback",
        "runtime_identity_gate": "not_implemented_in_public_v2.10.0_source",
        "parameter_package_sha256": PARAMETER_SHA256,
        "rights_notice": RIGHTS,
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
