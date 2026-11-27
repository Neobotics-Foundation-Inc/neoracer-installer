"""Tests for scripts/install.sh.

The installer erases the car and installs ROS2, so the suite never runs it for
real. Behavior is covered through --dry-run against a sandbox $HOME; the guards
that can only fire on a real run are covered by reading the script source.
The reinstall menu reads a terminal, so those runs put stdin on a pseudo-terminal.
"""

from __future__ import annotations

import os
import pty
import re
import shlex
import shutil
import subprocess
import termios
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
    for name in ("jupyter_ws", "ros2_ws/src", "neoracer_data", "logs"):
        (home / name).mkdir(parents=True)
    (home / "neoracer_data" / "run.bag").write_text("payload")
    return home, installer / "scripts" / "install.sh"


def run_installer(
    home: Path, script: Path, *args: str, extra_env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    # stdin is never a terminal here, even when pytest runs in one, so the
    # reinstall menu is not shown.
    env = dict(os.environ)
    env["HOME"] = str(home)
    env.update(extra_env or {})
    return subprocess.run(
        ["bash", str(script), *args],
        env=env,
        cwd=str(home),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=300,
    )


def run_installer_on_a_terminal(
    home: Path, script: Path, answers: str, *args: str, extra_env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    """Run the installer with stdin on a pseudo-terminal and type the answers.

    [ -t 0 ] is true on the terminal, so the reinstall menu is shown. stdout
    and stderr stay pipes. Echo is off, so the typed answers are not repeated.
    """
    env = dict(os.environ)
    env["HOME"] = str(home)
    env.update(extra_env or {})
    controller, terminal = pty.openpty()
    attrs = termios.tcgetattr(terminal)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(terminal, termios.TCSANOW, attrs)
    try:
        proc = subprocess.Popen(
            ["bash", str(script), *args],
            env=env,
            cwd=str(home),
            stdin=terminal,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    finally:
        os.close(terminal)
    try:
        os.write(controller, answers.encode())
        out, err = proc.communicate(timeout=300)
    finally:
        os.close(controller)
    return subprocess.CompletedProcess(proc.args, proc.returncode, out, err)


def newest_log(script: Path) -> str:
    return max((script.parent.parent / "logs").glob("install_*.log")).read_text()


def plain(out: str) -> str:
    """The output without its colour codes."""
    return re.sub(r"\x1b\[[0-9;]*m", "", out)


def run_function(
    script_source: str, name: str, home: Path, call: str, setup: str = ""
) -> subprocess.CompletedProcess[str]:
    """Run one function of install.sh on its own, against a temp $HOME.

    The function's text is cut from the script source. log and log_silent are
    replaced by plain writes, and setup can define more stand-ins, such as
    sudo or date, before the call.
    """
    start = script_source.index(f"\n{name}() {{\n") + 1
    end = script_source.index("\n}\n", start) + 3
    prelude = (
        'log() { echo "$1"; }\n'
        'log_silent() { echo "$1" >> "$LOG_FILE"; }\n'
        f"HOME={shlex.quote(str(home))}\n"
        'LOG_FILE="$HOME/function.log"\n'
        'JUPYTER_WS="$HOME/jupyter_ws"\n'
        "DRY_RUN=false\n"
    )
    return subprocess.run(
        ["bash", "-c", prelude + setup + "\n" + script_source[start:end] + call],
        cwd=str(home),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=60,
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
    for name in ("jupyter_ws", "ros2_ws", "neoracer_data", "logs"):
        assert (home / name).is_dir()
    assert (home / "neoracer_data" / "run.bag").read_text() == "payload"


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
    assert f"would move {home}/jupyter_ws to {home}/jupyter_ws-backup-" in out
    assert f"would remove {home}/ros2_ws" in out
    assert f"would remove {home}/logs" in out
    assert f"mkdir -p {home}/ros2_ws/src" in out
    assert f"mkdir -p {home}/logs" in out
    assert "git clone https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver.git" in out
    assert f"bash {home}/ros2_ws/src/neoracer_ros2_driver/scripts/setup_all.sh" in out


def test_data_root_is_never_erased_or_created(sandbox: tuple[Path, Path]) -> None:
    # Bags, maps and datasets live in ~/neoracer_data, which a reinstall must leave alone.
    # ~/data is no longer created: driver 0.9.0 writes nothing there, and its setup
    # moves an older car's camlabel images out of it into the data root.
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert f"would remove {home}/neoracer_data" not in out
    assert f"mkdir -p {home}/data" not in out
    log = next((script.parent.parent / "logs").glob("*.log")).read_text()
    assert "dir.neoracer_data.size_kb" in log


def test_driver_ref_selects_the_clone_branch(sandbox: tuple[Path, Path]) -> None:
    # DRIVER_REF names a branch or tag to install instead of the default branch,
    # for testing an unreleased driver on a car. Unset, the clone is unchanged.
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "--branch" not in out

    out = run_installer(
        home, script, "--dry-run", "--yes", extra_env={"DRIVER_REF": "port/mit-0.9.0"}
    ).stdout
    assert "DRIVER_REF=port/mit-0.9.0 would be cloned instead of the default branch" in out
    assert (
        "git clone --branch port/mit-0.9.0 "
        "https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver.git"
    ) in out


def test_driver_ref_is_resolved_before_the_erase(script_source: str) -> None:
    # A misspelled ref must stop the run while the car still has its software.
    lookup = script_source.index('"refs/heads/${DRIVER_REF}"')
    removal = script_source.index("[1/3] Removing existing systems and code")
    assert lookup < removal
    assert "No branch or tag named" in script_source[lookup:removal]


def test_help_documents_driver_ref() -> None:
    result = subprocess.run(["bash", str(INSTALL_SH), "--help"], capture_output=True, text=True)
    assert "DRIVER_REF" in result.stdout
    assert "DRIVER_URL" in result.stdout


DRIVER_0_9_0_UNITS = (
    "neoracer-teleop.service",
    "neoracer-watchdog.service",
    "neoracer-dashboard.service",
    "neoracer-jupyter.service",
    "neoracer-data.service",
    "neoracer-mapview.service",
    "neoracer-autonomy.service",
    "neoracer-camlabel.service",
    "neoracer-wallfollow.service",
    "neoracer-pursuit.service",
    "neoracer-eps.service",
    "neoracer-smartfollow.service",
    "neoracer-linefollow.service",
    "neoracer-webteleop.service",
)


def test_checks_name_every_driver_0_9_0_unit_and_file(script_source: str) -> None:
    # What the driver's setup_services.sh and setup_ros2.sh install at 0.9.0.
    for unit in DRIVER_0_9_0_UNITS:
        assert unit in script_source, f"{unit} is not checked"
    assert '"/etc/sudoers.d/neoracer"' in script_source
    assert '"/etc/profile.d/neoracer-data.sh"' in script_source
    for pkg in (
        "ros-humble-slam-toolbox",
        "ros-humble-nav2-map-server",
        "ros-humble-nav2-amcl",
        "ros-humble-nav2-lifecycle-manager",
        "ros-humble-robot-state-publisher",
        "ros-humble-xacro",
        "ros-humble-rosbag2-storage-mcap",
    ):
        assert pkg in script_source, f"{pkg} is not checked"


def test_snapshot_records_every_unit_and_the_driver_release(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    run_installer(home, script, "--dry-run", "--yes")
    log = next((script.parent.parent / "logs").glob("*.log")).read_text()
    for unit in DRIVER_0_9_0_UNITS:
        name = unit.removesuffix(".service")
        assert f"svc.{name}.enabled=" in log
        assert f"svc.{name}.active=" in log
    assert "ws.driver_pkg_version=" in log


def _fake_driver_checkout(home: Path, version: str) -> None:
    driver = home / "ros2_ws" / "src" / "neoracer_ros2_driver"
    (driver / ".git").mkdir(parents=True)
    (driver / "package.xml").write_text(
        f"<package><name>neoracer_ros2_driver</name><version>{version}</version></package>\n"
    )


def test_driver_release_must_match_the_installer(sandbox: tuple[Path, Path], script_source: str) -> None:
    # The installer's major.minor is the driver release it installs; the check reads
    # the driver's package.xml and fails on any other release.
    home, script = sandbox
    installer_version = re.search(r'^INSTALLER_VERSION="(\d+\.\d+)\.\d+"$', script_source, re.MULTILINE)
    assert installer_version
    release = installer_version.group(1)

    # Verdict tags carry colour codes, so the assertions match the text after them.
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "driver version unreadable" in out

    _fake_driver_checkout(home, f"{release}.7")
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert f"driver {release}.7 matches installer" in out

    shutil.rmtree(home / "ros2_ws" / "src" / "neoracer_ros2_driver")
    _fake_driver_checkout(home, "0.1.0")
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "driver 0.1.0 does not match installer" in out


def test_confirmation_names_what_is_kept(sandbox: tuple[Path, Path]) -> None:
    # The prompt says what the erase destroys, what survives it, and that a car
    # already on the driver has racecar update instead.
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert f"Kept: {home}/neoracer_data" in out
    assert "~/.config/racecar" in out
    assert "lab dashboard checkouts" in out
    assert "racecar update" in out


def test_sudoers_check_is_a_warning_in_a_dry_run(sandbox: tuple[Path, Path]) -> None:
    # Reading /etc/sudoers.d needs root; a dry run never asks for a password.
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "/etc/sudoers.d/neoracer not checked (needs sudo; dry run)" in out


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
    shutil.rmtree(home / "logs")
    (home / "logs").symlink_to(outside)

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


def test_racecar_user_required_before_removal(script_source: str) -> None:
    # The driver's setup stops for any other account; the installer checks first, before the erase.
    assert 'CAR_USER="racecar"' in script_source
    guard = script_source.index('[ "$CURRENT_USER" != "$CAR_USER" ]')
    snapshot = script_source.index('snapshot_state "before"')
    removal = script_source.index("[1/3] Removing existing systems and code")
    assert guard < snapshot < removal
    assert "Nothing has been removed." in script_source[guard:snapshot]


def test_dry_run_reports_the_user_check(sandbox: tuple[Path, Path]) -> None:
    # The sandbox home is never /home/racecar, so a dry run must say a real run would stop.
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "a real run would stop here" in out
    assert f"home {home}" in out


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


MENU = (
    "What should this run reinstall?\n"
    "  1) The driver and the student library. ~/jupyter_ws remains.\n"
    "  2) Everything. ~/jupyter_ws is erased too, and the newest labs are installed.\n"
    "Choose 1 or 2 [1]: "
)


def warning_block(out: str) -> str:
    start = out.index("[WARNING] The following directories will be erased:")
    return out[start : out.index("racecar update", start)]


def test_menu_text_is_exact(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer_on_a_terminal(home, script, "1\n", "--dry-run").stdout
    assert MENU in out
    # The menu comes before the warning, so the warning can list the chosen run.
    assert out.index(MENU) < out.index("[WARNING] The following directories will be erased:")


@pytest.mark.parametrize(
    ("answers", "choice", "prompts"),
    [
        ("1\n", "1", 1),
        ("2\n", "2", 1),
        ("\n", "1", 1),
        ("x\n1\n", "1", 2),
    ],
    ids=["one", "two", "enter", "invalid-then-one"],
)
def test_menu_answers(sandbox: tuple[Path, Path], answers: str, choice: str, prompts: int) -> None:
    # Enter picks 1. Any other answer than 1, 2 or empty shows the prompt again.
    home, script = sandbox
    result = run_installer_on_a_terminal(home, script, answers, "--dry-run")
    assert result.returncode == 0, result.stdout
    assert result.stdout.count("Choose 1 or 2 [1]: ") == prompts
    assert f"Reinstall choice: {choice} (menu)" in newest_log(script)


def test_menu_closed_without_an_answer_stops_the_run(sandbox: tuple[Path, Path]) -> None:
    # Ctrl-D at the prompt ends stdin. The run stops before the warning.
    home, script = sandbox
    result = run_installer_on_a_terminal(home, script, "\x04", "--dry-run")
    assert result.returncode == 1
    assert "No choice was made. Nothing has been removed." in result.stdout
    assert "[WARNING]" not in result.stdout


def test_yes_skips_the_menu_and_plans_choice_2(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert "What should this run reinstall?" not in out
    assert "This run reinstalls everything (choice 2). --yes skips the menu." in out
    assert "Reinstall choice: 2 (set by --yes)" in newest_log(script)
    assert f"{home}/jupyter_ws  (" in warning_block(out)


def test_dry_run_without_a_terminal_plans_choice_2(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    result = run_installer(home, script, "--dry-run")
    assert result.returncode == 0, result.stdout
    assert "What should this run reinstall?" not in result.stdout
    assert "there is no terminal for the menu, so the run plans choice 2" in result.stdout
    assert "Reinstall choice: 2 (no terminal)" in newest_log(script)
    assert f"{home}/jupyter_ws  (" in warning_block(result.stdout)


def test_warning_for_choice_1_keeps_jupyter_ws(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer_on_a_terminal(home, script, "1\n", "--dry-run").stdout
    warning = warning_block(out)
    assert f"{home}/ros2_ws  (" in warning
    assert f"{home}/logs  (" in warning
    assert f"{home}/jupyter_ws  (" not in warning
    assert "notebooks in" not in warning
    assert "Kept: ~/jupyter_ws (notebooks and labs)" in warning
    assert "lab dashboard checkouts under ~/ros2_ws." in warning


def test_warning_for_choice_2_lists_every_folder(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer_on_a_terminal(home, script, "2\n", "--dry-run").stdout
    warning = warning_block(out)
    for name in ("jupyter_ws", "ros2_ws", "logs"):
        assert f"{home}/{name}  (" in warning
    assert f"Kept: {home}/neoracer_data" in warning
    assert "Kept: ~/jupyter_ws" not in warning


def test_choice_1_leaves_jupyter_ws_out_of_the_erase(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer_on_a_terminal(home, script, "1\n", "--dry-run").stdout
    assert f"would remove {home}/jupyter_ws" not in out
    assert f"would remove {home}/ros2_ws" in out
    assert f"would remove {home}/logs" in out


def test_no_terminal_without_yes_stops_before_anything_changes(script_source: str) -> None:
    # The menu reads a terminal only. With no terminal and no -y, the
    # confirmation stops the run before the first step changes anything.
    menu = script_source.index('elif [ -t 0 ]; then\n    log ""\n    log "What should this run reinstall?"')
    warning = script_source.index('log "[WARNING] The following directories will be erased:"')
    stop = script_source.index("No terminal available to confirm the erase")
    removal = script_source.index("[1/3] Removing existing systems and code")
    assert menu < warning < stop < removal
    assert "exit 1" in script_source[stop:removal]


BACKUP_NAME = re.compile(r"jupyter_ws-backup-\d{8}-\d{6}")


def test_yes_plans_choice_2_with_the_backup(sandbox: tuple[Path, Path]) -> None:
    # -y keeps its old meaning, everything, and now moves ~/jupyter_ws to a
    # dated backup first. The erase then skips the moved folder.
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    planned = re.search(rf"would move {re.escape(str(home))}/jupyter_ws to {re.escape(str(home))}/({BACKUP_NAME.pattern})$", out, re.MULTILINE)
    assert planned, out
    assert f"would remove {home}/jupyter_ws" not in out
    assert (home / "jupyter_ws").is_dir()
    assert not list(home.glob("jupyter_ws-backup-*"))
    assert f"Backup:           {home}/{planned.group(1)} (dry run, not made)" in plain(out)
    assert "Old backups stay until someone deletes them." in out


def test_warning_for_choice_2_says_where_the_backup_goes(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    warning = warning_block(run_installer(home, script, "--dry-run", "--yes").stdout)
    assert "Anything you saved in ~/ros2_ws or ~/logs is gone for good" in warning
    assert "~/jupyter_ws is moved to ~/jupyter_ws-backup-YYYYMMDD-HHMMSS before" in warning
    assert "notebooks in" not in warning


def test_choice_1_makes_no_backup(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer_on_a_terminal(home, script, "1\n", "--dry-run").stdout
    assert "would move" not in out
    assert "jupyter_ws-backup-" not in out
    assert "Backup:" not in out


def test_backup_moves_jupyter_ws_beside_itself(tmp_path: Path, script_source: str) -> None:
    (tmp_path / "jupyter_ws" / "neoracer-os" / "labs").mkdir(parents=True)
    (tmp_path / "jupyter_ws" / "my_lab.ipynb").write_text("student work")
    result = run_function(
        script_source, "backup_jupyter_ws", tmp_path,
        'backup_jupyter_ws; echo "rc=$?"; echo "backup=$JUPYTER_BACKUP"',
    )
    assert "rc=0" in result.stdout, result.stdout
    backups = list(tmp_path.glob("jupyter_ws-backup-*"))
    assert len(backups) == 1
    assert BACKUP_NAME.fullmatch(backups[0].name)
    assert f"backup={backups[0]}" in result.stdout
    assert f"moved {tmp_path}/jupyter_ws to {backups[0]}" in result.stdout
    # The folder itself moved: its contents sit at the top of the backup.
    assert (backups[0] / "my_lab.ipynb").read_text() == "student work"
    assert (backups[0] / "neoracer-os" / "labs").is_dir()
    assert not (tmp_path / "jupyter_ws").exists()


def test_backup_never_reuses_an_existing_folder(tmp_path: Path, script_source: str) -> None:
    # A backup name that exists already stops the backup. Nothing moves, so the
    # new backup never lands inside the older one.
    (tmp_path / "jupyter_ws").mkdir()
    (tmp_path / "jupyter_ws" / "my_lab.ipynb").write_text("student work")
    older = tmp_path / "jupyter_ws-backup-20261127-141500"
    older.mkdir()
    (older / "old.ipynb").write_text("older work")
    result = run_function(
        script_source, "backup_jupyter_ws", tmp_path,
        'backup_jupyter_ws; echo "rc=$?"; echo "backup=$JUPYTER_BACKUP"',
        setup="date() { echo 20261127-141500; }",
    )
    assert "rc=1" in result.stdout, result.stdout
    assert "backup=\n" in result.stdout
    assert f"{older} exists already" in result.stdout
    assert sorted(p.name for p in older.iterdir()) == ["old.ipynb"]
    assert (tmp_path / "jupyter_ws" / "my_lab.ipynb").read_text() == "student work"


def test_backup_is_not_needed_without_jupyter_ws(tmp_path: Path, script_source: str) -> None:
    result = run_function(
        script_source, "backup_jupyter_ws", tmp_path,
        'backup_jupyter_ws; echo "rc=$?"; echo "backup=$JUPYTER_BACKUP"',
    )
    assert "rc=0" in result.stdout
    assert "backup=\n" in result.stdout
    assert "not present, so no backup is needed" in result.stdout
    assert not list(tmp_path.glob("jupyter_ws-backup-*"))


def test_backup_in_a_dry_run_moves_nothing(tmp_path: Path, script_source: str) -> None:
    (tmp_path / "jupyter_ws").mkdir()
    result = run_function(
        script_source, "backup_jupyter_ws", tmp_path,
        'backup_jupyter_ws; echo "rc=$?"', setup="DRY_RUN=true",
    )
    assert "rc=0" in result.stdout
    assert f"would move {tmp_path}/jupyter_ws to {tmp_path}/jupyter_ws-backup-" in result.stdout
    assert (tmp_path / "jupyter_ws").is_dir()
    assert not list(tmp_path.glob("jupyter_ws-backup-*"))


def test_failed_backup_stops_before_the_erase(script_source: str) -> None:
    # The backup runs after the services stop and before any folder is erased.
    # On failure the run starts the stopped units again and exits.
    removal = script_source.index("[1/3] Removing existing systems and code")
    stop = script_source.index("done < <(running_services)", removal)
    backup = script_source.index('if [ "$REINSTALL_CHOICE" = 2 ] && ! backup_jupyter_ws; then', removal)
    wipe = script_source.index('for path in "${WIPE_PATHS[@]}"', removal)
    assert stop < backup < wipe
    failure = script_source[backup:wipe]
    assert "restart_stopped_services" in failure
    assert "Nothing has been removed." in failure
    assert "exit 1" in failure


def test_stopped_services_are_started_again(tmp_path: Path, script_source: str) -> None:
    result = run_function(
        script_source, "restart_stopped_services", tmp_path,
        "restart_stopped_services",
        setup=(
            'sudo() { echo "sudo $*"; }\n'
            "STOPPED_SERVICES=(neoracer-teleop.service jupyterlab.service)"
        ),
    )
    assert "starting neoracer-teleop.service again" in result.stdout
    assert "starting jupyterlab.service again" in result.stdout
    log = (tmp_path / "function.log").read_text()
    assert "sudo systemctl start neoracer-teleop.service" in log
    assert "sudo systemctl start jupyterlab.service" in log


def _unit_dir(tmp_path: Path) -> Path:
    units = tmp_path / "systemd"
    (units / "multi-user.target.wants").mkdir(parents=True)
    for name in ("neoracer-teleop.service", "neoracer-camlabel.service", "jupyterlab.service"):
        (units / name).write_text("[Unit]\n")
    return units


def test_unit_files_plan_in_a_dry_run(tmp_path: Path, script_source: str) -> None:
    units = _unit_dir(tmp_path)
    result = run_function(
        script_source, "remove_unit_files", tmp_path, "remove_unit_files",
        setup=f"DRY_RUN=true\nUNIT_DIR={shlex.quote(str(units))}",
    )
    for svc in ("neoracer-camlabel.service", "neoracer-teleop.service"):
        assert f"[dry-run] would disable {svc}" in result.stdout
        assert f"[dry-run] would remove {units}/{svc}" in result.stdout
        assert (units / svc).is_file()
    assert "[dry-run] would run systemctl daemon-reload" in result.stdout
    assert "jupyterlab" not in result.stdout


def test_unit_files_are_disabled_then_removed(tmp_path: Path, script_source: str) -> None:
    # Each neoracer unit is disabled before its file goes, then systemd reloads
    # once. The vendor jupyterlab.service stays.
    units = _unit_dir(tmp_path)
    result = run_function(
        script_source, "remove_unit_files", tmp_path, "remove_unit_files",
        setup=(
            f"UNIT_DIR={shlex.quote(str(units))}\n"
            'sudo() { echo "sudo $*" >> "$HOME/calls"; "$@"; }\n'
            "systemctl() { :; }"
        ),
    )
    assert result.returncode == 0, result.stderr
    assert not (units / "neoracer-teleop.service").exists()
    assert not (units / "neoracer-camlabel.service").exists()
    assert (units / "jupyterlab.service").is_file()
    calls = (tmp_path / "calls").read_text().splitlines()
    for svc in ("neoracer-camlabel.service", "neoracer-teleop.service"):
        disable = calls.index(f"sudo systemctl disable {svc}")
        remove = calls.index(f"sudo rm -f -- {units}/{svc}")
        assert disable < remove
    assert calls[-1] == "sudo systemctl daemon-reload"
    assert calls.count("sudo systemctl daemon-reload") == 1
    assert not any("jupyterlab" in call for call in calls)


def test_no_unit_files_means_no_reload(tmp_path: Path, script_source: str) -> None:
    units = tmp_path / "systemd"
    units.mkdir()
    result = run_function(
        script_source, "remove_unit_files", tmp_path, "remove_unit_files",
        setup=(
            f"UNIT_DIR={shlex.quote(str(units))}\n"
            'sudo() { echo "sudo $*" >> "$HOME/calls"; }'
        ),
    )
    assert result.returncode == 0
    assert not (tmp_path / "calls").exists()


def test_unit_files_go_after_the_backup_and_before_the_erase(script_source: str) -> None:
    removal = script_source.index("[1/3] Removing existing systems and code")
    backup = script_source.index('if [ "$REINSTALL_CHOICE" = 2 ] && ! backup_jupyter_ws; then', removal)
    units = script_source.index("    remove_unit_files\n", removal)
    wipe = script_source.index('for path in "${WIPE_PATHS[@]}"', removal)
    assert backup < units < wipe
    assert 'UNIT_DIR="/etc/systemd/system"' in script_source
    start = script_source.index("\nremove_unit_files() {\n")
    body = script_source[start : script_source.index("\n}\n", start)]
    assert '"$UNIT_DIR"/neoracer-*.service' in body
    assert "sudoers" not in body
    assert "jupyterlab" not in body


@pytest.mark.parametrize("answers", ["1\n", "2\n"], ids=["choice-1", "choice-2"])
def test_warning_says_services_go_back_to_their_defaults(sandbox: tuple[Path, Path], answers: str) -> None:
    home, script = sandbox
    out = run_installer_on_a_terminal(home, script, answers, "--dry-run").stdout
    assert (
        "Services go back to their defaults. A service you turned off starts at boot again."
        in warning_block(out)
    )


def test_choice_1_runs_setup_with_labs_refresh_off(sandbox: tuple[Path, Path]) -> None:
    # A RACECAR_LABS_REFRESH=1 exported in the shell must not refresh the labs
    # that choice 1 keeps, so the setup command sets it to 0.
    home, script = sandbox
    out = run_installer_on_a_terminal(
        home, script, "1\n", "--dry-run", extra_env={"RACECAR_LABS_REFRESH": "1"}
    ).stdout
    assert (
        f"[dry-run] env RACECAR_LABS_REFRESH=0 bash {home}/ros2_ws/src/neoracer_ros2_driver/scripts/setup_all.sh"
        in out
    )


def test_choice_2_runs_setup_unchanged(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = run_installer(home, script, "--dry-run", "--yes").stdout
    assert f"[dry-run] bash {home}/ros2_ws/src/neoracer_ros2_driver/scripts/setup_all.sh" in out
    assert "RACECAR_LABS_REFRESH" not in out


def test_summary_and_check_for_choice_1(sandbox: tuple[Path, Path]) -> None:
    home, script = sandbox
    out = plain(run_installer_on_a_terminal(home, script, "1\n", "--dry-run").stdout)
    assert "Labs:             kept as they were. Run 'racecar update --labs' to refresh them." in out
    assert f"[PASS] {home}/jupyter_ws present" in out
    assert "recreated by the driver setup" not in out
    log = newest_log(script)
    assert "Labs:             kept as they were." in log


def test_summary_and_check_for_choice_2(sandbox: tuple[Path, Path]) -> None:
    # A dry run erases nothing, so the existing folder passes the choice 2 check.
    home, script = sandbox
    out = plain(run_installer(home, script, "--dry-run", "--yes").stdout)
    assert f"[PASS] {home}/jupyter_ws recreated by the driver setup" in out
    assert "Labs:" not in out
    assert "Backup:" in out
