from __future__ import annotations

import json
from pathlib import Path

ROOT = Path.cwd()
RIGHTS = "Copyright © 2026 Gateway Information Group LLC. All rights reserved."
OLD_BUILD = "NLD-2.10.0-PUBLIC-20260810-01"
NEW_BUILD = "NLD-2.10.0-PUBLIC-20260810-02"
TEMP_PATHS = {
    ".github/scripts/apply_comparison_root_hardening.py",
    ".github/workflows/apply_comparison_root_hardening.yml",
}


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def write_text(path: Path, text: str) -> None:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    newline = "\r\n" if path.suffix.lower() in {".ps1", ".cmd", ".bat"} else "\n"
    path.write_text(normalized, encoding="utf-8", newline=newline)


def replace_exact(path: Path, old: str, new: str, count: int = 1) -> None:
    text = read_text(path)
    actual = text.count(old)
    if actual != count:
        raise SystemExit(f"Expected {count} occurrence(s) in {path}, found {actual}: {old!r}")
    write_text(path, text.replace(old, new, count))


def patch_compare() -> None:
    path = ROOT / "Compare-NetLossDoctorReports.ps1"
    text = read_text(path)
    old_block = """$Script:Version = '2.10.0'
$ErrorActionPreference = 'Continue'
function New-SafeName([string]$s){ if([string]::IsNullOrWhiteSpace($s)){return 'unknown'}; $x=($s -replace '[^a-zA-Z0-9_.-]+','_').Trim('_'); if($x){$x}else{'unknown'} }
if ([string]::IsNullOrWhiteSpace($ReportsPath)) {
    $toolRoot = $env:NLD_HOME
    if ([string]::IsNullOrWhiteSpace($toolRoot) -or -not (Test-Path -LiteralPath $toolRoot)) { $toolRoot = $PSScriptRoot }
    if ([string]::IsNullOrWhiteSpace($toolRoot)) { $toolRoot = (Get-Location).Path }
    $ReportsPath = Join-Path (Join-Path $toolRoot 'exports') 'NetLossDoctor_Reports'
}
if (-not (Test-Path -LiteralPath $ReportsPath)) { New-Item -ItemType Directory -Path $ReportsPath -Force | Out-Null }
"""
    new_block = """$Script:Version = '2.10.0'
$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-02'
$ErrorActionPreference = 'Continue'
function New-SafeName([string]$s){ if([string]::IsNullOrWhiteSpace($s)){return 'unknown'}; $x=($s -replace '[^a-zA-Z0-9_.-]+','_').Trim('_'); if($x){$x}else{'unknown'} }
$toolRoot = $env:NLD_HOME
if ([string]::IsNullOrWhiteSpace($toolRoot) -or -not (Test-Path -LiteralPath $toolRoot -PathType Container)) { $toolRoot = $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($toolRoot) -or -not (Test-Path -LiteralPath $toolRoot -PathType Container)) {
    Write-Error 'Unable to resolve the NetLossDoctor project root from NLD_HOME or the comparison-script location. No comparison output was created.'
    exit 24
}
$toolRoot = [IO.Path]::GetFullPath($toolRoot)
if ([string]::IsNullOrWhiteSpace($ReportsPath)) {
    $ReportsPath = Join-Path (Join-Path $toolRoot 'exports') 'NetLossDoctor_Reports'
} elseif (-not [IO.Path]::IsPathRooted($ReportsPath)) {
    $ReportsPath = Join-Path $toolRoot $ReportsPath
}
$ReportsPath = [IO.Path]::GetFullPath($ReportsPath)
try {
    if (-not (Test-Path -LiteralPath $ReportsPath -PathType Container)) {
        New-Item -ItemType Directory -Path $ReportsPath -Force -ErrorAction Stop | Out-Null
    }
} catch {
    Write-Error ("Unable to create the selected comparison report root '{0}'. No caller-CWD, Desktop, or OS-temp fallback will be used. {1}" -f $ReportsPath, $_.Exception.Message)
    exit 25
}
"""
    if text.count(old_block) != 1:
        raise SystemExit("Expected comparison root-resolution block was not found exactly once")
    text = text.replace(old_block, new_block, 1)
    if "(Get-Location).Path" in text:
        raise SystemExit("Caller-working-directory fallback remains in comparison helper")
    write_text(path, text)


def patch_engine() -> None:
    replace_exact(ROOT / "NetLossDoctor.ps1", OLD_BUILD, NEW_BUILD)


def patch_metadata() -> None:
    path = ROOT / "PUBLIC_SOURCE_METADATA.json"
    metadata = json.loads(read_text(path))
    if metadata.get("build_id") != OLD_BUILD:
        raise SystemExit(f"Unexpected current public build ID: {metadata.get('build_id')!r}")
    metadata["build_id"] = NEW_BUILD
    metadata["comparison_helper"] = "Compare-NetLossDoctorReports.ps1"
    metadata["comparison_root_resolution"] = (
        "validated NLD_HOME override or comparison-script location; caller CWD is not authority"
    )
    metadata["relative_reports_root_policy"] = "rebase_from_resolved_project_root"
    metadata["output_failure_policy"] = (
        "fail_closed_no_cwd_desktop_or_os_temp_final_output_fallback"
    )
    write_text(path, json.dumps(metadata, indent=2, ensure_ascii=False) + "\n")


def patch_readme() -> None:
    path = ROOT / "README.md"
    text = read_text(path)
    old = """Compare recent result bundles with:

```powershell
powershell.exe -NoProfile -File .\\Compare-NetLossDoctorReports.ps1 -ReportsPath .\\exports\\NetLossDoctor_Reports
```
"""
    new = """Compare recent result bundles with:

```powershell
powershell.exe -NoProfile -File .\\Compare-NetLossDoctorReports.ps1 -ReportsPath .\\exports\\NetLossDoctor_Reports
```

The comparison helper uses the same project-root rule as the collector. A relative `-ReportsPath` is rebased from the helper's project folder, not the caller's working directory; an absolute path remains an explicit user-selected external binding. If the selected location cannot be created, comparison fails closed instead of writing to caller CWD, Desktop, or operating-system temporary storage.
"""
    if text.count(old) != 1:
        raise SystemExit("README comparison example marker was not found exactly once")
    write_text(path, text.replace(old, new, 1))


def patch_tests() -> None:
    path = ROOT / "tests/Test-SafetyContracts.ps1"
    text = read_text(path)
    replacements = [
        (
            "Assert-True ($publicMetadata.build_id -eq 'NLD-2.10.0-PUBLIC-20260810-01') 'Public source build ID changed.'",
            "Assert-True ($publicMetadata.build_id -eq 'NLD-2.10.0-PUBLIC-20260810-02') 'Public source build ID changed.'",
        ),
        (
            "Assert-True ($engine -match \"\\$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-01'\") 'Transparent public build ID is missing.'",
            "Assert-True ($engine -match \"\\$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-02'\") 'Transparent public build ID is missing.'",
        ),
    ]
    for old, new in replacements:
        if text.count(old) != 1:
            raise SystemExit(f"Expected test marker was not found exactly once: {old!r}")
        text = text.replace(old, new, 1)

    metadata_anchor = (
        "Assert-True ($publicMetadata.backend_target -eq 'NetLossDoctor.ps1') 'Backend-target metadata changed.'\n"
    )
    metadata_add = metadata_anchor + (
        "Assert-True ($publicMetadata.comparison_helper -eq 'Compare-NetLossDoctorReports.ps1') 'Comparison-helper metadata changed.'\n"
        "Assert-True ($publicMetadata.relative_reports_root_policy -eq 'rebase_from_resolved_project_root') 'Relative report-root policy changed.'\n"
    )
    if text.count(metadata_anchor) != 1:
        raise SystemExit("Metadata test anchor was not found exactly once")
    text = text.replace(metadata_anchor, metadata_add, 1)

    static_anchor = (
        "Assert-True ($engine -match 'New-Item -ItemType Directory -Path \\$Path -Force -ErrorAction Stop') 'Directory creation must be terminating so fail-closed handling can run.'\n"
    )
    static_add = static_anchor + (
        "Assert-True ($compare -match \"\\$Script:BuildId = 'NLD-2.10.0-PUBLIC-20260810-02'\") 'Comparison helper build ID is missing.'\n"
        "Assert-True ($compare -notmatch '\\(Get-Location\\)\\.Path') 'Comparison helper must not use caller CWD as project-root authority.'\n"
        "Assert-True ($compare -match '\\[IO\\.Path\\]::IsPathRooted\\(\\$ReportsPath\\)') 'Relative comparison paths must be identified before rebasing.'\n"
        "Assert-True ($compare -match \"New-Item -ItemType Directory -Path \\$ReportsPath -Force -ErrorAction Stop\") 'Comparison output creation must be terminating.'\n"
        "Assert-True ($compare -match 'No caller-CWD, Desktop, or OS-temp fallback will be used') 'Comparison fail-closed output error is missing.'\n"
    )
    if text.count(static_anchor) != 1:
        raise SystemExit("Static test anchor was not found exactly once")
    text = text.replace(static_anchor, static_add, 1)

    footer = (
        "Write-Host (\"PASS: parsed {0} PowerShell files and verified safety invariants.\" -f $powerShellFiles.Count) -ForegroundColor Green\n"
    )
    comparison_test = """$compareFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('NetLossDoctor_CompareRoot_' + [guid]::NewGuid().ToString('N'))
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

""" + footer
    if text.count(footer) != 1:
        raise SystemExit("Test footer marker was not found exactly once")
    text = text.replace(footer, comparison_test, 1)
    write_text(path, text)


def main() -> int:
    patch_compare()
    patch_engine()
    patch_metadata()
    patch_readme()
    patch_tests()
    print(json.dumps({
        "project": "NetLossDoctor",
        "version": "2.10.0",
        "build_id": NEW_BUILD,
        "comparison_helper": "Compare-NetLossDoctorReports.ps1",
        "root_policy": "script_or_validated_NLD_HOME_not_caller_cwd",
        "relative_path_policy": "rebase_from_resolved_project_root",
        "output_failure_policy": "fail_closed_no_cwd_desktop_or_os_temp_final_output_fallback",
        "rights_notice": RIGHTS,
    }, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
