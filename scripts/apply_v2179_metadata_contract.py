from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / "tests" / "Test-SafetyContracts.ps1"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected one source match, found {count}")
    return text.replace(old, new, 1)


def main() -> None:
    text = TEST.read_text(encoding="utf-8-sig")
    text = replace_once(
        text,
        "Assert-True ($publicMetadata.build_id -eq 'NLD-2.10.0-PUBLIC-20260810-02') 'Public source build ID changed.'\n",
        "Assert-True ($publicMetadata.build_id -eq 'NLD-2.10.0-PUBLIC-20260810-02') 'Public source build ID changed.'\n"
        "Assert-True ($publicMetadata.parameter_baseline -eq '2.17.9') 'Parameter baseline is not aligned to 2.17.9.'\n"
        "Assert-True ($publicMetadata.parameter_package_sha256 -eq 'fafe3f4a972b1f4def6e10faee7febc3c75154b8b346949991bb9d86e8a610df') 'Parameter package checksum changed.'\n",
        "parameter metadata assertions",
    )
    text = replace_once(
        text,
        "Assert-True ($publicMetadata.runtime_identity_gate.status -eq 'not_implemented_in_public_v2.10.0_source') 'Runtime identity claim boundary changed.'\n",
        "Assert-True ($publicMetadata.runtime_identity_gate.status -eq 'not_required_for_current_public_source') 'Runtime identity applicability boundary changed.'\n"
        "Assert-True (-not [bool]$publicMetadata.user_profile_fallback_allowed) 'User-profile fallback must remain disabled.'\n"
        "Assert-True ([int]$publicMetadata.file_inventory_and_consolidation.canonical_launcher_count -eq 1) 'Canonical launcher inventory changed.'\n"
        "Assert-True ([int]$publicMetadata.file_inventory_and_consolidation.exact_duplicate_files_detected -eq 0) 'Exact duplicate inventory changed.'\n"
        "Assert-True ([bool]$publicMetadata.launch_verification.root_relative) 'Root-relative launcher metadata is missing.'\n"
        "Assert-True ([bool]$publicMetadata.launch_verification.argument_forwarding) 'Launcher argument-forwarding metadata is missing.'\n"
        "Assert-True ([bool]$publicMetadata.launch_verification.foreign_working_directory_ci) 'Foreign-working-directory launch verification metadata is missing.'\n"
        "Assert-True (-not [bool]$publicMetadata.launch_verification.caller_working_directory_output_allowed) 'Caller-CWD output must remain disabled.'\n",
        "runtime identity and launch assertions",
    )
    TEST.write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    main()
