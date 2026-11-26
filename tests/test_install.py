"""Tests for scripts/install.sh.

The installer erases the car and installs ROS2, so the suite never runs it for
real. Behavior is covered through --dry-run against a sandbox $HOME; the guards
that can only fire on a real run are covered by reading the script source.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
INSTALL_SH = REPO_ROOT / "scripts" / "install.sh"


@pytest.fixture(scope="session")
def script_source() -> str:
    return INSTALL_SH.read_text()


@pytest.fixture
def sandbox(tmp_path: Path) -> tuple[Path, Path]:
    """A throwaway $HOME plus a copy of the installer inside it.

    Returns (home, script). The copy keeps LOG_DIR inside tmp_path so runs
    never write into the real repository.
    """
    home = tmp_path / "home"
    installer = home / "neoracer-installer"
    (installer / "scripts").mkdir(parents=True)
    shutil.copy2(INSTALL_SH, installer / "scripts" / "install.sh")
    for name in ("jupyter_ws", "ros2_ws/src", "data", "logs"):
        (home / name).mkdir(parents=True)
    (home / "data" / "run.bag").write_text("payload")
    return home, installer / "scripts" / "install.sh"


def run_installer(home: Path, script: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ)
    env["HOME"] = str(home)
    return subprocess.run(
        ["bash", str(script), *args],
        env=env,
        cwd=str(home),
        capture_output=True,
        text=True,
        timeout=300,
    )


def test_script_is_executable() -> None:
    assert INSTALL_SH.is_file()
    assert os.access(INSTALL_SH, os.X_OK)
    assert INSTALL_SH.read_text().startswith("#!/usr/bin/env bash")


def test_script_parses() -> None:
    result = subprocess.run(["bash", "-n", str(INSTALL_SH)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_help_lists_every_step() -> None:
    result = subprocess.run(["bash", str(INSTALL_SH), "--help"], capture_output=True, text=True)
    assert result.returncode == 0
    for step in ("[1/3]", "[2/3]", "[3/3]"):
        assert step in result.stdout
    assert "[4/" not in result.stdout


def test_unknown_option_is_rejected() -> None:
    result = subprocess.run(["bash", str(INSTALL_SH), "--wipe-everything"], capture_output=True, text=True)
    assert result.returncode == 1
    assert "Unknown option" in result.stdout


def test_help_writes_no_log(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--help")
    assert not (script.parent.parent / "logs").exists()


def test_dry_run_keeps_every_file(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    result = run_installer(home, script, "--dry-run", "--yes")
    assert result.returncode == 0, result.stdout
    for name in ("jupyter_ws", "ros2_ws", "data", "logs"):
        assert (home / name).is_dir()
    assert (home / "data" / "run.bag").read_text() == "payload"


def test_dry_run_reports_every_step(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "[1/3] Removing existing systems and code" in out
    assert "[2/3] Creating workspace folders" in out
    assert "[3/3] Cloning the driver and running its setup" in out
    assert "Running post-install diagnostics" in out
    assert "sudo reboot" in out


def test_no_account_link_step(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "neobotics.org" not in out
    assert "account link" not in out.lower()


def test_dry_run_plans_the_documented_commands(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert f"would remove {home}/jupyter_ws" in out
    assert f"mkdir -p {home}/ros2_ws/src" in out
    assert f"mkdir -p {home}/data" in out
    assert f"mkdir -p {home}/logs" in out
    assert "git clone https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver.git" in out
    assert f"bash {home}/ros2_ws/src/neoracer_ros2_driver/scripts/setup_all.sh" in out


def test_each_run_writes_its_own_log(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    log_dir = script.parent.parent / "logs"
    run_installer(home, script, "--dry-run", "--yes")
    first = sorted(log_dir.glob("install_*.log"))
    assert len(first) == 1
    assert "INSTALL LOG START" in first[0].read_text()
    assert "INSTALL LOG END (DRY RUN)" in first[0].read_text()

    # Timestamped filenames give one file per run; a second run must not
    # truncate the first.
    subprocess.run(["sleep", "1.1"], check=True)
    run_installer(home, script, "--dry-run", "--yes")
    assert len(sorted(log_dir.glob("install_*.log"))) == 2


def test_log_records_diagnostic_verdicts(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--dry-run", "--yes")
    log_text = next((script.parent.parent / "logs").glob("install_*.log")).read_text()
    assert "[PASS]" in log_text or "[FAIL]" in log_text
    assert "INSTALLATION SUMMARY" in log_text


def test_driver_version_reported_before_and_after(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert out.count("Driver version") == 2, "version block missing before or after the run"
    assert "  installed:  none" in out
    assert "  incoming:   not checked (dry run)" in out
    assert "  previous:   none" in out


def test_driver_version_block_precedes_removal(script_source: str) -> None:
    version_block = script_source.index('log "Driver version"')
    removal = script_source.index("[1/3] Removing existing systems and code")
    assert version_block < removal


def test_driver_revisions_compared_by_full_sha(script_source: str) -> None:
    # Short SHAs widen when a prefix is ambiguous, so equality tests must use
    # the full hashes.
    assert '[ "$DRIVER_SHA_BEFORE" = "$DRIVER_REMOTE_HEAD" ]' in script_source
    assert '[ "$DRIVER_SHA_AFTER" = "$DRIVER_REMOTE_HEAD" ]' in script_source


def test_state_captures_driver_version_fields(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--dry-run", "--yes")
    log_text = next((script.parent.parent / "logs").glob("install_*.log")).read_text()
    for key in ("ws.driver_version=", "ws.driver_branch=", "ws.driver_commit_date="):
        assert f"[STATE:before] {key}" in log_text


def test_log_holds_before_and_after_state(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--dry-run", "--yes")
    log_text = next((script.parent.parent / "logs").glob("install_*.log")).read_text()
    for marker in ("STATE:before ==========", "STATE:after ==========", "STATE:diff =========="):
        assert marker in log_text


def test_state_captures_device_identifiers(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--dry-run", "--yes")
    log_text = next((script.parent.parent / "logs").glob("install_*.log")).read_text()
    for key in (
        "device.model=",
        "device.serial=",
        "device.machine_id=",
        "device.hostname=",
        "os.kernel=",
        "os.l4t=",
        "usb.count=",
        "udev.racecar_rules=",
    ):
        assert f"[STATE:before] {key}" in log_text, f"{key} not captured"


def test_state_captures_a_mac_address(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--dry-run", "--yes")
    log_text = next((script.parent.parent / "logs").glob("install_*.log")).read_text()
    macs = re.findall(r"\[STATE:before\] net\.\S+\.mac=([0-9a-f:]{17})$", log_text, re.MULTILINE)
    assert macs, "no interface MAC captured"


def test_state_snapshot_is_taken_before_removal(script_source: str) -> None:
    snapshot = script_source.index('snapshot_state "before"')
    removal = script_source.index("[1/3] Removing existing systems and code")
    assert snapshot < removal


def test_state_temp_files_are_cleaned_up(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--dry-run", "--yes")
    assert not list((script.parent.parent / "logs").glob(".state_*"))


def test_removal_refuses_a_target_outside_home(sandbox: tuple[Path, Path], tmp_path: Path) -> None:
    home, script = sandbox
    outside = tmp_path / "elsewhere"
    outside.mkdir()
    (outside / "important.txt").write_text("keep")
    shutil.rmtree(home / "data")
    (home / "data").symlink_to(outside)

    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "refusing to remove" in out
    assert (outside / "important.txt").exists()


def test_diagnostics_cover_every_driver_phase(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    for phase in (
        "ROS2 Humble and dev tools",
        "user environment",
        "udev rules",
        "workspace build",
        "GPU stack",
        "JupyterLab and student library",
        "systemd services",
    ):
        assert phase in out, f"no diagnostic section for {phase}"


def test_version_is_stamped_and_documented(script_source: str) -> None:
    match = re.search(r'^INSTALLER_VERSION="(\d+\.\d+\.\d+)"$', script_source, re.MULTILINE)
    assert match, "install.sh carries no INSTALLER_VERSION"
    version = match.group(1)

    result = subprocess.run(["bash", str(INSTALL_SH), "--help"], capture_output=True, text=True)
    assert version in result.stdout

    changelog = (REPO_ROOT / "docs" / "changelog.md").read_text()
    assert f"## [{version}]" in changelog, f"changelog has no {version} entry"


def test_root_is_refused(script_source: str) -> None:
    assert '[ "$(id -u)" -eq 0 ]' in script_source
    assert "Do not run this installer as root" in script_source


def test_removal_guard_covers_home_and_root(script_source: str) -> None:
    assert '""|"/"|"$HOME"|"$HOME/")' in script_source


def test_confirmation_required_without_a_terminal(script_source: str) -> None:
    assert 'elif [ ! -t 0 ]; then' in script_source
    assert "No terminal available to confirm the erase" in script_source


def test_repo_is_reachable_before_anything_is_erased(script_source: str) -> None:
    preflight = script_source.index("git ls-remote")
    removal = script_source.index("[1/3] Removing existing systems and code")
    assert preflight < removal


def test_every_running_service_is_stopped_before_removal(script_source: str) -> None:
    # The confirmation prompt lists WIPE_PATHS too; the erase loop is the one after the step banner.
    removal = script_source.index("[1/3] Removing existing systems and code")
    stop = script_source.index("'neoracer-*.service' 'jupyterlab.service'")
    wipe = script_source.index('for path in "${WIPE_PATHS[@]}"', removal)
    assert removal < stop < wipe
    # A unit waiting to restart after a crash is "activating"; it must be stopped too.
    assert "--state=active,activating" in script_source
