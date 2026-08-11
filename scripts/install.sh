#!/usr/bin/env bash

# Neoracer system software installer.
#
# Wipes the car's software state, re-clones the ROS2 driver, and re-runs the
# driver's own setup orchestrator, then verifies every component it installed.
# Target: Jetson Orin Nano, JetPack 6.x / Ubuntu 22.04 (Jammy), ROS2 Humble.
#
# Usage: bash neoracer-installer/scripts/install.sh [-y] [--dry-run]

# static variables
DRIVER_URL="https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver.git"
DRIVER_NAME="neoracer_ros2_driver"
LIDAR_NAME="lakibeam1"
ACCOUNT_URL="https://neobotics.org/"

WS_DIR="$HOME/ros2_ws"
SRC_DIR="$WS_DIR/src"
JUPYTER_WS="$HOME/jupyter_ws"
DATA_DIR="$HOME/data"
CAR_LOG_DIR="$HOME/logs"

# Paths wiped by step 1, in removal order.
WIPE_PATHS=("$JUPYTER_WS" "$WS_DIR" "$DATA_DIR" "$CAR_LOG_DIR")

# Paths created by step 2.
CREATE_PATHS=("$SRC_DIR" "$DATA_DIR" "$CAR_LOG_DIR")

# Core systemd units installed by the driver's setup_services.sh.
CORE_SERVICES=(
    neoracer-teleop.service
    neoracer-watchdog.service
    neoracer-dashboard.service
    neoracer-jupyter.service
)

# Get the full path of the current script
SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$(cd "$(dirname "$0")"; pwd)/$(basename "$0")")

# Extract the directory from the full path
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")

# Extract the neoracer-installer directory
INSTALLER_DIR=$(dirname "$SCRIPT_DIR")

# ============================================================================
# Argument parsing
# ============================================================================
ASSUME_YES=false
DRY_RUN=false

usage() {
    cat <<'USAGEEOF'
Neoracer system software installer.

Usage: bash neoracer-installer/scripts/install.sh [options]

Options:
  -y, --yes       Skip the confirmation prompt before erasing car software.
      --dry-run   Print every action without erasing, cloning, or installing.
  -h, --help      Show this message.

Steps:
  [1/4] Remove ~/jupyter_ws, ~/ros2_ws, ~/data, ~/logs
  [2/4] Create ~/ros2_ws/src, ~/data, ~/logs
  [3/4] Clone the driver and run scripts/setup_all.sh
  [4/4] Link the car to a neobotics.org account (pending implementation)

Every run is logged to neoracer-installer/logs/.
USAGEEOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes)   ASSUME_YES=true ;;
        --dry-run)  DRY_RUN=true ;;
        -h|--help)  usage; exit 0 ;;
        *)
            echo -e "\e[1;31m[ERROR] Unknown option: $1\e[0m"
            echo ""
            usage
            exit 1
            ;;
    esac
    shift
done

# ============================================================================
# Logging setup
# ============================================================================
LOG_DIR="${INSTALLER_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/install_$(date '+%Y-%m-%d_%H-%M-%S').log"

# Log a message to both the console and the log file
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$LOG_FILE"
    echo "$1"
}

# Log a message to the log file only (for verbose/debug output)
log_silent() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Run a command, logging its output to the log file while showing it on screen
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] $*"
        return 0
    fi
    log_silent "RUNNING: $*"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -ne 0 ]; then
        log_silent "WARNING: Command exited with code $exit_code: $*"
    fi
    return $exit_code
}

# Run a piped command string (for commands like "yes | sudo apt install ...")
run_pipe() {
    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] $*"
        return 0
    fi
    log_silent "RUNNING: $*"
    eval "$*" 2>&1 | tee -a "$LOG_FILE"
    local exit_code=${PIPESTATUS[0]}
    if [ $exit_code -ne 0 ]; then
        log_silent "WARNING: Command exited with code $exit_code: $*"
    fi
    return $exit_code
}

# Capture start time for duration calculation
INSTALL_START_TIME=$(date +%s)

# Log system info for debugging
log_silent "========== INSTALL LOG START =========="
log_silent "Date: $(date)"
log_silent "User: $(whoami)"
log_silent "Home: $HOME"
log_silent "Shell: $SHELL"
log_silent "Kernel: $(uname -a)"
log_silent "OS: $(lsb_release -ds 2>/dev/null || echo unknown)"
log_silent "L4T: $(cat /etc/nv_tegra_release 2>/dev/null || echo 'not a Tegra board')"
log_silent "INSTALLER_DIR: $INSTALLER_DIR"
log_silent "Installer revision: $(git -C "$INSTALLER_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
log_silent "Flags: assume_yes=${ASSUME_YES} dry_run=${DRY_RUN}"
log_silent "======================================="

echo ""
echo -e "\e[1;36m=========================================================================="
log 'Welcome to the Neoracer system software installer.'
echo -e "==========================================================================\e[0m"
log "This erases the car's software and reinstalls it from scratch."
log "Install log: $LOG_FILE"
if [ "$DRY_RUN" = true ]; then
    echo ""
    echo -e "\e[33m[DRY RUN] No files will be removed and nothing will be installed.\e[0m"
fi
log ""

# ============================================================================
# Preflight checks
#
# Everything that can abort the run is checked before step 1 erases anything.
# A car left with no software because the network dropped mid-clone is worse
# than a car that never started the install.
# ============================================================================
log "Running preflight checks..."

if [ "$(id -u)" -eq 0 ]; then
    echo -e "\e[1;31m[ERROR] Do not run this installer as root or with sudo.\e[0m"
    log "Run it as the car's normal user; it asks for a sudo password when needed."
    log_silent "========== INSTALL LOG END (ABORTED: running as root) =========="
    exit 1
fi

MISSING_TOOLS=""
for tool in git curl bash sudo; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS} ${tool}"
done
if [ -n "$MISSING_TOOLS" ]; then
    echo -e "\e[1;31m[ERROR] Missing required tools:${MISSING_TOOLS}\e[0m"
    log "Install them with: sudo apt-get install -y${MISSING_TOOLS}"
    log_silent "========== INSTALL LOG END (ABORTED: missing tools) =========="
    exit 1
fi
log "  [OK] required tools present (git, curl, bash, sudo)"

if [ "$DRY_RUN" = false ]; then
    if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code -h "$DRIVER_URL" >/dev/null 2>&1; then
        echo -e "\e[1;31m[ERROR] Cannot reach the driver repository:\e[0m"
        log "  $DRIVER_URL"
        log "Connect the car to the internet and run the installer again."
        log "Nothing has been removed."
        log_silent "========== INSTALL LOG END (ABORTED: driver repo unreachable) =========="
        exit 1
    fi
    log "  [OK] driver repository reachable"
else
    log "  [dry-run] skipping driver repository reachability check"
fi

# The driver's setup scripts call sudo throughout. Prompt for the password now,
# while the car still has its old software, instead of 20 minutes in.
if [ "$DRY_RUN" = false ]; then
    log ""
    log "The driver setup needs sudo. Enter your password if prompted."
    if ! sudo -v; then
        echo -e "\e[1;31m[ERROR] sudo authentication failed.\e[0m"
        log "Nothing has been removed."
        log_silent "========== INSTALL LOG END (ABORTED: sudo failed) =========="
        exit 1
    fi
    # Keep sudo alive for the whole run.
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
    log "  [OK] sudo authenticated"
fi

# rm -rf on the current working directory leaves the shell in a deleted inode
# and every later relative path resolves against nothing.
cd "$HOME" || exit 1

# ============================================================================
# Confirmation
# ============================================================================
log ""
echo -e "\e[33m=========================================================================="
log "[WARNING] The following directories will be erased:"
echo "=========================================================================="
for path in "${WIPE_PATHS[@]}"; do
    if [ -e "$path" ]; then
        SIZE=$(du -sh "$path" 2>/dev/null | cut -f1)
        log "  ${path}  (${SIZE:-unknown size})"
    else
        log "  ${path}  (not present)"
    fi
done
echo ""
echo "Anything you saved in these folders, including notebooks in ~/jupyter_ws"
echo "and recordings in ~/data, is gone for good. Back them up first."
echo -e "==========================================================================\e[0m"
log ""

if [ "$ASSUME_YES" = true ]; then
    log "Confirmation skipped (--yes)."
elif [ "$DRY_RUN" = true ]; then
    log "Confirmation skipped (--dry-run)."
elif [ ! -t 0 ]; then
    echo -e "\e[1;31m[ERROR] No terminal available to confirm the erase.\e[0m"
    log "Re-run with -y to confirm non-interactively."
    log_silent "========== INSTALL LOG END (ABORTED: cannot confirm) =========="
    exit 1
else
    echo -n "Type 'yes' to erase and reinstall: "
    read -r CONFIRM
    log_silent "Confirmation response: ${CONFIRM}"
    if [ "$CONFIRM" != "yes" ]; then
        log ""
        log "Aborted. Nothing has been removed."
        log_silent "========== INSTALL LOG END (ABORTED: declined) =========="
        exit 1
    fi
fi

# ============================================================================
# [1/4] Removal of existing systems and code
# ============================================================================
log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "[1/4] Removing existing systems and code..."
echo -e "\e[1;36m==========================================================================\e[0m"

# Remove one explicit path, refusing anything outside $HOME or $HOME itself.
remove_path() {
    local target="$1"
    local resolved
    resolved=$(readlink -f "$target" 2>/dev/null || echo "$target")

    case "$resolved" in
        ""|"/"|"$HOME"|"$HOME/")
            log "  [SKIP] refusing to remove '${target}' (resolves to '${resolved}')"
            log_silent "REFUSED unsafe removal target: ${target} -> ${resolved}"
            return 1
            ;;
        "$HOME"/*) ;;
        *)
            log "  [SKIP] refusing to remove '${target}' (outside \$HOME)"
            log_silent "REFUSED out-of-home removal target: ${target} -> ${resolved}"
            return 1
            ;;
    esac

    if [ ! -e "$target" ]; then
        log "  [ -- ] ${target} (not present)"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] would remove ${target}"
        return 0
    fi

    log_silent "REMOVING: ${target} (resolved: ${resolved})"
    rm -rf -- "$target"
    local rc=$?
    if [ $rc -eq 0 ]; then
        log "  [ OK ] removed ${target}"
        return 0
    fi
    log "  [FAIL] could not remove ${target}"
    log_silent "WARNING: Command exited with code ${rc}: rm -rf ${target}"
    return 1
}

# The core services hold open files under ~/logs and ~/ros2_ws. Stop them
# first so removal does not race a running node.
if [ "$DRY_RUN" = false ] && command -v systemctl >/dev/null 2>&1; then
    for svc in "${CORE_SERVICES[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log "  stopping ${svc}"
            sudo systemctl stop "$svc" >>"$LOG_FILE" 2>&1
        fi
    done
fi

for path in "${WIPE_PATHS[@]}"; do
    remove_path "$path"
done

# ============================================================================
# [2/4] Folder creation
# ============================================================================
log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "[2/4] Creating workspace folders..."
echo -e "\e[1;36m==========================================================================\e[0m"

for path in "${CREATE_PATHS[@]}"; do
    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] mkdir -p ${path}"
        continue
    fi
    if mkdir -p "$path"; then
        log "  [ OK ] ${path}"
    else
        log "  [FAIL] ${path}"
        log_silent "WARNING: mkdir -p failed for ${path}"
    fi
done

# ============================================================================
# [3/4] Driver clone and setup
# ============================================================================
log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "[3/4] Cloning the driver and running its setup..."
echo -e "\e[1;36m==========================================================================\e[0m"
log "This phase installs ROS2 Humble, builds the workspace, and installs the"
log "GPU stack. It takes 30 to 60 minutes on a fresh car; keep the car powered"
log "and connected to the internet."
log ""

if [ "$DRY_RUN" = false ] && ! cd "$SRC_DIR"; then
    echo -e "\e[1;31m[ERROR] Cannot enter ${SRC_DIR}. Step 2 did not complete.\e[0m"
    log_silent "========== INSTALL LOG END (ABORTED: no src dir) =========="
    exit 1
fi

log "Cloning ${DRIVER_URL}"
CLONE_RC=0
run_cmd git clone "$DRIVER_URL" || CLONE_RC=$?

SETUP_SCRIPT="${SRC_DIR}/${DRIVER_NAME}/scripts/setup_all.sh"
SETUP_RC=0

if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] bash ${SETUP_SCRIPT}"
elif [ "$CLONE_RC" -ne 0 ] || [ ! -f "$SETUP_SCRIPT" ]; then
    echo ""
    echo -e "\e[1;31m=========================================================================="
    echo "[ERROR] The driver clone failed; there is no setup script to run."
    echo "=========================================================================="
    echo "  Expected: ${SETUP_SCRIPT}"
    echo ""
    echo "Check the car's internet connection and re-run this installer."
    echo -e "==========================================================================\e[0m"
    echo ""
    log_silent "Clone rc=${CLONE_RC}, setup script present: $([ -f "$SETUP_SCRIPT" ] && echo yes || echo no)"
    SETUP_RC=1
else
    log ""
    log "Running ${SETUP_SCRIPT}"
    run_cmd bash "$SETUP_SCRIPT" || SETUP_RC=$?
    if [ "$SETUP_RC" -ne 0 ]; then
        echo ""
        echo -e "\e[1;31m[ERROR] The driver setup exited with code ${SETUP_RC}.\e[0m"
        log "Diagnostics below show which components are missing."
    fi
fi

# ============================================================================
# [4/4] Account link
#
# TBD: bind this car to its owner's neobotics.org account. The endpoint,
# payload, and credential handling are not specified yet, so the step only
# confirms the site is reachable; a car that cannot reach it is flagged at
# install time rather than the first time someone opens the web dashboard.
#
# When the API lands, replace the reachability probe with the registration
# call and turn ACCOUNT_LINK_STATE into pass/fail.
# ============================================================================
log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "[4/4] Linking the car to a neobotics.org account..."
echo -e "\e[1;36m==========================================================================\e[0m"

ACCOUNT_LINK_STATE="pending"
if [ "$DRY_RUN" = true ]; then
    log "  [dry-run] ping ${ACCOUNT_URL}"
elif curl -sf --max-time 15 -o /dev/null "$ACCOUNT_URL" 2>>"$LOG_FILE"; then
    log "  [ OK ] ${ACCOUNT_URL} is reachable"
else
    ACCOUNT_LINK_STATE="unreachable"
    log "  [WARN] ${ACCOUNT_URL} is not reachable from this car"
fi
log "  Account linking is not implemented yet; register the car at ${ACCOUNT_URL}"

# ============================================================================
# Post-install diagnostics
#
# One check per component the driver setup installs, so a failed run names the
# phase to re-run instead of just reporting that something went wrong.
# ============================================================================
log ""
log "Running post-install diagnostics..."
log "=========================================================================="

PASS=0
FAIL=0
WARN=0

check_pass() {
    echo -e "  \e[32m[PASS]\e[0m $1"
    log_silent "[PASS] $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo -e "  \e[31m[FAIL]\e[0m $1"
    log_silent "[FAIL] $1"
    FAIL=$((FAIL + 1))
}

# Conditions the installer cannot control: unplugged hardware, an unspecified
# account API. Reported, but they do not fail the run.
check_warn() {
    echo -e "  \e[33m[WARN]\e[0m $1"
    log_silent "[WARN] $1"
    WARN=$((WARN + 1))
}

section() {
    echo ""
    echo -e "  \e[1m$1\e[0m"
    log_silent "--- $1 ---"
}

# Run a command with base ROS2 and the neoracer overlay sourced.
in_ros_env() {
    (
        # ROS2 setup scripts read unset variables.
        set +u
        source /opt/ros/humble/setup.bash >/dev/null 2>&1 || exit 1
        [ -f "${WS_DIR}/install/setup.bash" ] && source "${WS_DIR}/install/setup.bash" >/dev/null 2>&1
        "$@"
    )
}

section "Step 1-2: workspace layout"

for path in "${CREATE_PATHS[@]}"; do
    if [ -d "$path" ]; then
        check_pass "${path} exists"
    else
        check_fail "${path} not found"
    fi
done

# setup_jupyter.sh recreates ~/jupyter_ws, so a missing one means that phase
# never ran.
if [ -d "$JUPYTER_WS" ]; then
    check_pass "${JUPYTER_WS} recreated by the driver setup"
else
    check_fail "${JUPYTER_WS} not found (JupyterLab phase did not run)"
fi

section "Step 3: driver checkout"

if [ -d "${SRC_DIR}/${DRIVER_NAME}/.git" ]; then
    DRIVER_REV=$(git -C "${SRC_DIR}/${DRIVER_NAME}" rev-parse --short HEAD 2>/dev/null)
    check_pass "${DRIVER_NAME} cloned (${DRIVER_REV:-unknown revision})"
else
    check_fail "${DRIVER_NAME} not cloned into ${SRC_DIR}"
fi

if [ -f "$SETUP_SCRIPT" ]; then
    check_pass "setup_all.sh present in the checkout"
else
    check_fail "setup_all.sh missing from the checkout"
fi

section "Step 3, phase 1-2: ROS2 Humble and dev tools"

if [ -f /opt/ros/humble/setup.bash ]; then
    check_pass "ROS2 Humble installed (/opt/ros/humble)"
else
    check_fail "ROS2 Humble not installed; re-run scripts/setup_ros2.sh"
fi

if in_ros_env command -v ros2 >/dev/null 2>&1; then
    check_pass "ros2 command available"
else
    check_fail "ros2 command not available"
fi

MISSING_ROS_PKGS=""
for pkg in ros-humble-ackermann-msgs ros-humble-cv-bridge ros-humble-foxglove-bridge; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_ROS_PKGS="${MISSING_ROS_PKGS} ${pkg}"
done
if [ -z "$MISSING_ROS_PKGS" ]; then
    check_pass "driver ROS packages installed (ackermann-msgs, cv-bridge, foxglove-bridge)"
else
    check_fail "missing ROS packages:${MISSING_ROS_PKGS}"
fi

MISSING_TOOLS=""
for tool in colcon cmake rosdep; do
    command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS} ${tool}"
done
if [ -z "$MISSING_TOOLS" ]; then
    check_pass "build tools available (colcon, cmake, rosdep)"
else
    check_fail "missing build tools:${MISSING_TOOLS}; re-run scripts/setup_dev_tools.sh"
fi

section "Step 3, phase 3: user environment"

if grep -qF "# Neoracer - default workspace" "$HOME/.bashrc" 2>/dev/null; then
    check_pass "default-workspace block in ~/.bashrc"
else
    check_fail "default-workspace block missing from ~/.bashrc"
fi

if grep -qF "# Neoracer - shell tool" "$HOME/.bashrc" 2>/dev/null; then
    check_pass "racecar shell tool sourced from ~/.bashrc"
else
    check_fail "racecar shell tool not sourced from ~/.bashrc"
fi

if [ -f "${SRC_DIR}/${DRIVER_NAME}/scripts/racecar-tool.sh" ]; then
    check_pass "racecar-tool.sh present"
else
    check_fail "racecar-tool.sh not found in the driver checkout"
fi

# usermod takes effect at the next login, so id -nG on this shell still shows
# the old set; getent reads the group file itself.
MISSING_GROUPS=""
for grp in dialout video; do
    if getent group "$grp" >/dev/null 2>&1; then
        getent group "$grp" | grep -qw "$USER" || MISSING_GROUPS="${MISSING_GROUPS} ${grp}"
    fi
done
if [ -z "$MISSING_GROUPS" ]; then
    check_pass "${USER} is in the dialout and video groups (active after reboot)"
else
    check_fail "${USER} missing from groups:${MISSING_GROUPS}"
fi

section "Step 3, phase 4: udev rules"

if [ -f /etc/udev/rules.d/99-racecar.rules ]; then
    check_pass "99-racecar.rules installed"
else
    check_fail "99-racecar.rules not installed; re-run scripts/setup_udev.sh"
fi

for dev in /dev/osrbot_base /dev/osrbot_led_matrix /dev/osrbot_usb_cam; do
    if [ -e "$dev" ]; then
        check_pass "${dev} present"
    else
        check_warn "${dev} absent (device unplugged, powered off, or not yet re-plugged)"
    fi
done

section "Step 3, phase 5: workspace build"

if [ -f "${WS_DIR}/install/setup.bash" ]; then
    check_pass "workspace built (${WS_DIR}/install/setup.bash)"
else
    check_fail "workspace not built; re-run scripts/setup_workspace.sh"
fi

for pkg in "$DRIVER_NAME" "$LIDAR_NAME"; do
    if [ -d "${WS_DIR}/install/${pkg}" ]; then
        check_pass "package ${pkg} installed into the workspace"
    else
        check_fail "package ${pkg} missing from ${WS_DIR}/install"
    fi
done

if in_ros_env ros2 pkg list 2>/dev/null | grep -qx "$DRIVER_NAME"; then
    check_pass "ros2 pkg list reports ${DRIVER_NAME}"
else
    check_fail "${DRIVER_NAME} not visible to ros2 pkg list"
fi

section "Step 3, phase 6: GPU stack"

if python3 -c "import torch" >/dev/null 2>&1; then
    TORCH_VER=$(python3 -c "import torch; print(torch.__version__)" 2>/dev/null)
    check_pass "torch importable (${TORCH_VER})"
    if python3 -c "import sys, torch; sys.exit(0 if torch.cuda.is_available() else 1)" >/dev/null 2>&1; then
        check_pass "torch.cuda.is_available() is True"
    else
        check_fail "torch is installed but CUDA is unavailable (CPU-only wheel or driver mismatch)"
    fi
else
    check_fail "torch not importable; re-run scripts/setup_ml.sh"
fi

if python3 -c "import tensorrt" >/dev/null 2>&1; then
    TRT_VER=$(python3 -c "import tensorrt; print(tensorrt.__version__)" 2>/dev/null)
    check_pass "tensorrt importable (${TRT_VER})"
else
    check_fail "tensorrt not importable"
fi

if python3 -c "import ultralytics" >/dev/null 2>&1; then
    check_pass "ultralytics importable"
else
    check_fail "ultralytics not importable"
fi

section "Step 3, phase 7: JupyterLab and student library"

if [ -x "$HOME/.local/bin/jupyter" ]; then
    check_pass "jupyter installed (~/.local/bin/jupyter)"
else
    check_fail "jupyter not installed; re-run scripts/setup_jupyter.sh"
fi

if [ -d "${JUPYTER_WS}/neoracer-os/library" ]; then
    check_pass "student library installed (~/jupyter_ws/neoracer-os/library)"
else
    check_fail "student library not installed"
fi

if [ -d "${JUPYTER_WS}/neoracer-os/labs" ]; then
    check_pass "labs installed (~/jupyter_ws/neoracer-os/labs)"
else
    check_fail "labs not installed"
fi

USER_SITE=$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null)
if [ -n "$USER_SITE" ] && [ -f "${USER_SITE}/racecar_student.pth" ]; then
    check_pass "racecar_student.pth wires the library onto sys.path"
else
    check_fail "racecar_student.pth not written to the user site-packages"
fi

if python3 -c "import racecar_core" >/dev/null 2>&1; then
    check_pass "racecar_core importable"
else
    check_fail "racecar_core not importable from a plain python3"
fi

section "Step 3, phase 8: systemd services"

if command -v systemctl >/dev/null 2>&1; then
    for svc in "${CORE_SERVICES[@]}"; do
        if [ ! -f "/etc/systemd/system/${svc}" ]; then
            check_fail "${svc} not installed"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            check_pass "${svc} installed and enabled at boot"
        else
            check_fail "${svc} installed but not enabled"
        fi
    done
else
    check_warn "systemctl unavailable; cannot verify services"
fi

section "Step 4: account link"

case "$ACCOUNT_LINK_STATE" in
    pending)     check_warn "account linking not implemented yet (register at ${ACCOUNT_URL})" ;;
    unreachable) check_warn "${ACCOUNT_URL} unreachable; the car cannot be registered until it has internet" ;;
esac

section "Run log"

LOG_ERRORS=$(grep -c "WARNING: Command exited with code" "$LOG_FILE" 2>/dev/null)
LOG_ERRORS=${LOG_ERRORS:-0}
if [ "$LOG_ERRORS" -gt 0 ]; then
    check_fail "log records ${LOG_ERRORS} command failure(s); review $LOG_FILE"
else
    check_pass "no command failures recorded in the log"
fi

# Results summary
log ""
log "=========================================================================="
TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
    echo -e "  \e[1;32mAll ${TOTAL} checks passed.\e[0m"
    log_silent "All ${TOTAL} checks passed."
else
    echo -e "  \e[1;31m${FAIL} of ${TOTAL} checks failed.\e[0m Review the log: $LOG_FILE"
    log_silent "${FAIL} of ${TOTAL} checks failed."
fi
if [ $WARN -gt 0 ]; then
    echo -e "  \e[33m${WARN} warning(s); see above.\e[0m"
fi
log "=========================================================================="

# ============================================================================
# Installation summary
# ============================================================================
INSTALL_END_TIME=$(date +%s)
INSTALL_DURATION=$((INSTALL_END_TIME - INSTALL_START_TIME))
INSTALL_MINUTES=$((INSTALL_DURATION / 60))
INSTALL_SECONDS=$((INSTALL_DURATION % 60))

log ""
echo -e "\e[1;36m======================== INSTALLATION SUMMARY ========================\e[0m"
echo -e "  Driver:           \e[1m${DRIVER_NAME} ${DRIVER_REV:-not cloned}\e[0m"
echo -e "  Workspace:        \e[1m${WS_DIR}\e[0m"
echo -e "  Checks:           \e[1m${PASS}/${TOTAL} passed, ${WARN} warning(s)\e[0m"
echo -e "  Log file:         \e[1m${LOG_FILE}\e[0m"
echo -e "  Duration:         \e[1m${INSTALL_MINUTES}m ${INSTALL_SECONDS}s\e[0m"
echo -e "\e[1;36m======================================================================\e[0m"

log_silent "======================== INSTALLATION SUMMARY ========================"
log_silent "  Driver:           ${DRIVER_NAME} ${DRIVER_REV:-not cloned}"
log_silent "  Workspace:        ${WS_DIR}"
log_silent "  Checks:           ${PASS}/${TOTAL} passed, ${WARN} warning(s)"
log_silent "  Log file:         ${LOG_FILE}"
log_silent "  Duration:         ${INSTALL_MINUTES}m ${INSTALL_SECONDS}s"
log_silent "======================================================================"

# ============================================================================
# Reboot notice
#
# The group changes from setup_user_env.sh, the udev symlinks, and the enabled
# services all take effect at the next boot.
# ============================================================================
echo ""
echo -e "\e[1;31m##########################################################################"
echo "##                                                                      ##"
echo "##   Reboot now to complete setup:  sudo reboot                         ##"
echo "##                                                                      ##"
echo "##   Group membership, udev symlinks, and the racecar services only     ##"
echo "##   take effect after a reboot.                                        ##"
echo "##                                                                      ##"
echo -e "##########################################################################\e[0m"
echo ""

if [ "$DRY_RUN" = true ]; then
    echo -e "\e[33m[DRY RUN] Nothing was changed. Diagnostics above describe the car as it is now.\e[0m"
    log_silent "========== INSTALL LOG END (DRY RUN) =========="
    exit 0
fi

if [ $FAIL -eq 0 ]; then
    echo -e "\e[1;32mNeoracer setup complete.\e[0m"
    log_silent "========== INSTALL LOG END =========="
    exit 0
fi

echo -e "\e[1;31mNeoracer setup finished with ${FAIL} failed check(s).\e[0m"
log_silent "========== INSTALL LOG END (WITH FAILURES) =========="
exit 1
