#!/usr/bin/env bash

# Neoracer system software installer.
#
# Wipes the car's software state, re-clones the ROS2 driver, and re-runs the
# driver's own setup orchestrator, then verifies every component it installed.
# Target: Jetson Orin Nano, JetPack 6.x / Ubuntu 22.04 (Jammy), ROS2 Humble.
#
# Usage: bash neoracer-installer/scripts/install.sh [-y] [--dry-run]

# static variables
INSTALLER_VERSION="0.2.2"
DRIVER_URL="https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver.git"
DRIVER_NAME="neoracer_ros2_driver"
LIDAR_NAME="lakibeam1"

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
    echo "Neoracer system software installer, version ${INSTALLER_VERSION}."
    cat <<'USAGEEOF'

Usage: bash neoracer-installer/scripts/install.sh [options]

Options:
  -y, --yes       Skip the confirmation prompt before erasing car software.
      --dry-run   Print every action without erasing, cloning, or installing.
  -h, --help      Show this message.

Steps:
  [1/3] Remove ~/jupyter_ws, ~/ros2_ws, ~/data, ~/logs
  [2/3] Create ~/ros2_ws/src, ~/data, ~/logs
  [3/3] Clone the driver and run scripts/setup_all.sh

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

# Snapshots taken before and after the run; compared into a [STATE:diff] block.
BEFORE_STATE="${LOG_DIR}/.state_before_$$.tmp"
AFTER_STATE="${LOG_DIR}/.state_after_$$.tmp"

cleanup() {
    [ -n "${SUDO_KEEPALIVE_PID:-}" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    rm -f "$BEFORE_STATE" "$AFTER_STATE"
}
trap cleanup EXIT

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

# ============================================================================
# System state capture
#
# One key=value line per fact, written to a snapshot file and mirrored into the
# log under a [STATE:<phase>] prefix. Snapshots are taken before the erase and
# after the driver setup, then compared, so a support request carries what the
# car was, what it became, and what the run changed.
#
# Identifiers here are device identifiers (board serial, MAC addresses, disk
# serials) and stay in the local log. Nothing reads credentials, key material,
# or Wi-Fi secrets.
# ============================================================================

# Print one key=value line; missing facts are recorded as "unknown" rather than
# dropped, so a key that disappears in the diff means the fact itself changed.
emit() {
    printf '%s=%s\n' "$1" "${2:-unknown}"
}

# One human-readable line describing the revision a checkout sits on:
# "9c6902a (v1.2.0, 2026-08-05) Merge pull request #15 from ...". The tag is
# included only when HEAD is exactly on one. Returns non-zero if the directory
# is not a git checkout, so callers can distinguish "absent" from "unreadable".
describe_checkout() {
    local dir="$1"
    [ -d "${dir}/.git" ] || return 1

    local rev date subject tag
    rev=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null) || return 1
    date=$(git -C "$dir" log -1 --format='%cs' 2>/dev/null)
    subject=$(git -C "$dir" log -1 --format='%s' 2>/dev/null | cut -c1-60)
    tag=$(git -C "$dir" describe --tags --exact-match HEAD 2>/dev/null)

    if [ -n "$tag" ]; then
        printf '%s (%s, %s) %s' "$rev" "$tag" "${date:-unknown date}" "$subject"
    else
        printf '%s (%s) %s' "$rev" "${date:-unknown date}" "$subject"
    fi
}

# Device-tree strings are NUL-terminated.
dt_read() {
    [ -r "$1" ] && tr -d '\0' < "$1"
}

capture_state() {
    local ws_dir="$WS_DIR"

    # --- identity ---------------------------------------------------------
    emit "device.model" "$(dt_read /proc/device-tree/model)"
    emit "device.serial" "$(dt_read /proc/device-tree/serial-number)"
    # compatible is a NUL-separated list; the first entry names the board.
    emit "device.compatible" "$(tr '\0' '\n' < /proc/device-tree/compatible 2>/dev/null | head -1)"
    emit "device.machine_id" "$(cat /etc/machine-id 2>/dev/null)"
    emit "device.boot_id" "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    emit "device.hostname" "$(hostname 2>/dev/null)"
    emit "device.cpu_serial" "$(awk -F': ' '/^Serial/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    emit "device.power_mode" "$(nvpmodel -q 2>/dev/null | awk -F': ' '/NV Power Mode/ {print $2; exit}')"

    # --- platform ---------------------------------------------------------
    emit "os.release" "$(lsb_release -ds 2>/dev/null | tr -d '"')"
    emit "os.kernel" "$(uname -r)"
    emit "os.arch" "$(uname -m)"
    emit "os.l4t" "$(sed -n 's/^# R\([0-9]*\).*REVISION: \([0-9.]*\).*/R\1.\2/p' /etc/nv_tegra_release 2>/dev/null | head -1)"
    # Vendor image line, when the flashing tool left one; names which board
    # image a car was provisioned from.
    emit "os.image" "$(sed -n 's/^# .*Image Name \(.*\)$/\1/p' /etc/nv_tegra_release 2>/dev/null | head -1)"
    emit "os.jetpack" "$(dpkg-query -W -f='${Version}' nvidia-jetpack 2>/dev/null)"
    emit "os.cuda" "$(basename "$(readlink -f /usr/local/cuda 2>/dev/null)" 2>/dev/null)"
    emit "os.python3" "$(python3 --version 2>&1 | awk '{print $2}')"
    emit "host.uptime_s" "$(awk '{print int($1)}' /proc/uptime 2>/dev/null)"

    # --- capacity ---------------------------------------------------------
    emit "mem.total_kb" "$(awk '/^MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)"
    emit "disk.root_avail_kb" "$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
    emit "disk.home_avail_kb" "$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"

    # --- network ----------------------------------------------------------
    # MAC per interface: the stable per-device identifier when the board serial
    # is unreadable, and the way to tell two cars apart in a shared log dump.
    local iface
    for iface in /sys/class/net/*; do
        [ -e "$iface" ] || continue
        local name
        name=$(basename "$iface")
        [ "$name" = "lo" ] && continue
        emit "net.${name}.mac" "$(cat "${iface}/address" 2>/dev/null)"
        emit "net.${name}.state" "$(cat "${iface}/operstate" 2>/dev/null)"
        emit "net.${name}.ipv4" "$(ip -4 -o addr show dev "$name" 2>/dev/null | awk '{print $4}' | paste -sd, -)"
    done
    emit "net.default_route" "$(ip route show default 2>/dev/null | awk 'NR==1 {print $3 " via " $5}')"
    emit "net.wifi_ssid" "$(iwgetid -r 2>/dev/null)"

    # --- storage and peripherals -----------------------------------------
    # -P quotes every value: disk models contain spaces and empty serials would
    # otherwise shift the columns.
    local line dname
    while IFS= read -r line; do
        dname=$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<< "$line")
        case "$dname" in ""|loop*|zram*|ram*) continue ;; esac
        emit "storage.${dname}.size" "$(sed -n 's/.*SIZE="\([^"]*\)".*/\1/p' <<< "$line")"
        emit "storage.${dname}.model" "$(sed -n 's/.*MODEL="\([^"]*\)".*/\1/p' <<< "$line")"
        emit "storage.${dname}.serial" "$(sed -n 's/.*SERIAL="\([^"]*\)".*/\1/p' <<< "$line")"
    done < <(lsblk -dn -P -o NAME,SIZE,MODEL,SERIAL 2>/dev/null)

    emit "usb.count" "$(lsusb 2>/dev/null | wc -l)"
    local n=0 line
    while read -r line; do
        n=$((n + 1))
        emit "usb.device.${n}" "$(echo "$line" | sed 's/^Bus [0-9]* Device [0-9]*: //')"
    done < <(lsusb 2>/dev/null | sort)

    local dev
    for dev in /dev/osrbot_base /dev/osrbot_led_matrix /dev/osrbot_usb_cam; do
        if [ -e "$dev" ]; then
            emit "peripheral.$(basename "$dev")" "$(readlink -f "$dev" 2>/dev/null || echo present)"
        else
            emit "peripheral.$(basename "$dev")" "absent"
        fi
    done
    emit "peripheral.video_nodes" "$(ls -d /dev/video* 2>/dev/null | paste -sd, -)"

    # --- software inventory ----------------------------------------------
    emit "pkg.ros_base" "$(dpkg-query -W -f='${Version}' ros-humble-ros-base 2>/dev/null)"
    emit "pkg.colcon" "$(dpkg-query -W -f='${Version}' python3-colcon-common-extensions 2>/dev/null)"
    python3 - <<'PYEOF' 2>/dev/null
from importlib.metadata import PackageNotFoundError, version

for dist in ("torch", "torchvision", "numpy", "ultralytics", "onnx",
             "tensorrt", "jupyterlab", "opencv-python", "pytest"):
    try:
        found = version(dist)
    except (PackageNotFoundError, Exception):
        found = "absent"
    print(f"pkg.{dist.replace('-', '_')}={found}")
PYEOF

    # --- workspace and services -------------------------------------------
    emit "ws.installer_version" "$INSTALLER_VERSION"
    emit "ws.installer_rev" "$(git -C "$INSTALLER_DIR" rev-parse --short HEAD 2>/dev/null)"
    if [ -d "${SRC_DIR}/${DRIVER_NAME}/.git" ]; then
        local driver_dir="${SRC_DIR}/${DRIVER_NAME}"
        emit "ws.driver_rev" "$(git -C "$driver_dir" rev-parse --short HEAD 2>/dev/null)"
        emit "ws.driver_version" "$(describe_checkout "$driver_dir")"
        emit "ws.driver_branch" "$(git -C "$driver_dir" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        emit "ws.driver_commit_date" "$(git -C "$driver_dir" log -1 --format='%cs' 2>/dev/null)"
        emit "ws.driver_dirty" "$([ -n "$(git -C "$driver_dir" status --porcelain 2>/dev/null)" ] && echo yes || echo no)"
    else
        emit "ws.driver_rev" "absent"
        emit "ws.driver_version" "absent"
        emit "ws.driver_branch" "absent"
        emit "ws.driver_commit_date" "absent"
        emit "ws.driver_dirty" "absent"
    fi
    if [ -d "${SRC_DIR}/${LIDAR_NAME}/.git" ]; then
        emit "ws.lidar_rev" "$(git -C "${SRC_DIR}/${LIDAR_NAME}" describe --tags --always 2>/dev/null)"
    else
        emit "ws.lidar_rev" "absent"
    fi
    emit "ws.installed_packages" "$(ls -1 "${ws_dir}/install" 2>/dev/null | grep -cv '^\(setup\.\|local_setup\|_local_setup\|COLCON_IGNORE\)' )"

    local path
    for path in "$JUPYTER_WS" "$WS_DIR" "$DATA_DIR" "$CAR_LOG_DIR"; do
        emit "dir.$(basename "$path").size_kb" "$(du -sk "$path" 2>/dev/null | cut -f1)"
    done

    local svc
    for svc in "${CORE_SERVICES[@]}"; do
        emit "svc.${svc%.service}.enabled" "$(systemctl is-enabled "$svc" 2>/dev/null || echo absent)"
        emit "svc.${svc%.service}.active" "$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
    done
    emit "udev.racecar_rules" "$([ -f /etc/udev/rules.d/99-racecar.rules ] && echo present || echo absent)"
}

# Take a snapshot, mirror it into the log, and keep the file for the diff.
snapshot_state() {
    local phase="$1" dest="$2"
    capture_state > "$dest" 2>/dev/null
    log_silent "========== STATE:${phase} =========="
    while read -r line; do
        log_silent "[STATE:${phase}] ${line}"
    done < "$dest"
    log_silent "========== STATE:${phase} END =========="
}

# Report what the run changed. host.uptime_s always moves and says nothing, so
# it is dropped; every other key is worth seeing, including the disk and
# directory sizes the install consumed.
diff_state() {
    [ -s "$BEFORE_STATE" ] && [ -s "$AFTER_STATE" ] || return 0

    local changes
    changes=$(awk -F= '
        NR == FNR { before[$1] = substr($0, index($0, "=") + 1); next }
        {
            key = $1
            val = substr($0, index($0, "=") + 1)
            if (!(key in before))        print "added   " key " = " val
            else if (before[key] != val) print "changed " key ": " before[key] " -> " val
            delete before[key]
        }
        END { for (k in before) print "removed " k " = " before[k] }
    ' "$BEFORE_STATE" "$AFTER_STATE" | grep -v ' host.uptime_s' | sort)

    log_silent "========== STATE:diff =========="
    if [ -z "$changes" ]; then
        log_silent "[STATE:diff] no differences"
    else
        while read -r line; do
            log_silent "[STATE:diff] ${line}"
        done <<< "$changes"
    fi
    log_silent "========== STATE:diff END =========="

    local count
    count=$(printf '%s\n' "$changes" | grep -c . )
    log "  ${count} system state key(s) changed; see [STATE:diff] in $LOG_FILE"
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
log_silent "Installer version: ${INSTALLER_VERSION}"
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

# Snapshot before anything is touched, and before the confirmation prompt, so
# even a declined run leaves a record of what this car was.
snapshot_state "before" "$BEFORE_STATE"
STATE_MODEL=$(awk -F= '/^device\.model=/ {print substr($0, index($0, "=") + 1)}' "$BEFORE_STATE")
STATE_SERIAL=$(awk -F= '/^device\.serial=/ {print substr($0, index($0, "=") + 1)}' "$BEFORE_STATE")
STATE_HOST=$(awk -F= '/^device\.hostname=/ {print substr($0, index($0, "=") + 1)}' "$BEFORE_STATE")
log "  [OK] system state recorded"
log "       device:   ${STATE_MODEL:-unknown}"
log "       serial:   ${STATE_SERIAL:-unknown}"
log "       hostname: ${STATE_HOST:-unknown}"

DRIVER_REMOTE_HEAD=""
if [ "$DRY_RUN" = false ]; then
    # One call does double duty: it proves the repository is reachable and
    # names the revision the clone in step 3 will land on, so the incoming
    # version can be shown before anything is erased.
    DRIVER_REMOTE_HEAD=$(GIT_TERMINAL_PROMPT=0 git ls-remote "$DRIVER_URL" HEAD 2>/dev/null | awk 'NR==1 {print $1}')
    if [ -z "$DRIVER_REMOTE_HEAD" ]; then
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

# ============================================================================
# Driver version, before the erase
#
# The installed revision comes from the checkout about to be deleted; the
# incoming one from the remote HEAD resolved above. Both are shown before the
# confirmation prompt so the operator sees what the run replaces and with what.
# ============================================================================
DRIVER_VERSION_BEFORE=$(describe_checkout "${SRC_DIR}/${DRIVER_NAME}") || DRIVER_VERSION_BEFORE=""
DRIVER_REV_BEFORE="${DRIVER_VERSION_BEFORE%% *}"
# Compare full SHAs; rev-parse --short widens beyond 7 characters whenever a
# prefix is ambiguous, so short forms are for display only.
DRIVER_SHA_BEFORE=$(git -C "${SRC_DIR}/${DRIVER_NAME}" rev-parse HEAD 2>/dev/null)
DRIVER_REMOTE_SHORT="${DRIVER_REMOTE_HEAD:0:7}"

log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "Driver version"
echo -e "\e[1;36m==========================================================================\e[0m"
if [ -n "$DRIVER_VERSION_BEFORE" ]; then
    log "  installed:  ${DRIVER_VERSION_BEFORE}"
else
    log "  installed:  none (no driver checkout at ${SRC_DIR}/${DRIVER_NAME})"
fi

if [ "$DRY_RUN" = true ]; then
    log "  incoming:   not checked (dry run)"
elif [ -z "$DRIVER_VERSION_BEFORE" ]; then
    log "  incoming:   ${DRIVER_REMOTE_SHORT} (remote HEAD)"
    log "  status:     first install"
elif [ "$DRIVER_SHA_BEFORE" = "$DRIVER_REMOTE_HEAD" ]; then
    log "  incoming:   ${DRIVER_REMOTE_SHORT} (remote HEAD)"
    log "  status:     already at the newest revision; the run rebuilds it from scratch"
else
    log "  incoming:   ${DRIVER_REMOTE_SHORT} (remote HEAD)"
    log "  status:     update available (${DRIVER_REV_BEFORE} -> ${DRIVER_REMOTE_SHORT})"
fi
log_silent "Driver remote HEAD: ${DRIVER_REMOTE_HEAD:-unknown}"

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
    # Keep sudo alive for the whole run; cleanup() kills it on exit.
    ( while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
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
# [1/3] Removal of existing systems and code
# ============================================================================
log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "[1/3] Removing existing systems and code..."
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

# Every running or restarting unit that holds files under the folders about to
# go, stopped first so removal does not race a running node: the four core
# services, the lab dashboards and autonomy (neoracer-*.service, installed by
# the driver's setup_services.sh) and the vendor image's jupyterlab.service,
# which serves ~/jupyter_ws until the driver's phase 8 retires it. A unit
# waiting out its RestartSec after a crash is "activating", not "active", so
# both states are listed; stopping it also cancels the pending restart.
# Stopped, not disabled: the driver's setup decides what runs at boot.
running_services() {
    systemctl list-units --type=service --state=active,activating --plain --no-legend \
        'neoracer-*.service' 'jupyterlab.service' 2>/dev/null | awk '{print $1}'
}
if command -v systemctl >/dev/null 2>&1; then
    while read -r svc; do
        [ -n "$svc" ] || continue
        if [ "$DRY_RUN" = true ]; then
            log "  [dry-run] would stop ${svc}"
        else
            log "  stopping ${svc}"
            sudo systemctl stop "$svc" >>"$LOG_FILE" 2>&1
        fi
    done < <(running_services)
fi

for path in "${WIPE_PATHS[@]}"; do
    remove_path "$path"
done

# ============================================================================
# [2/3] Folder creation
# ============================================================================
log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "[2/3] Creating workspace folders..."
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
# [3/3] Driver clone and setup
# ============================================================================
log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "[3/3] Cloning the driver and running its setup..."
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
# Driver version, after the run
# ============================================================================
DRIVER_VERSION_AFTER=$(describe_checkout "${SRC_DIR}/${DRIVER_NAME}") || DRIVER_VERSION_AFTER=""
DRIVER_REV_AFTER="${DRIVER_VERSION_AFTER%% *}"
DRIVER_SHA_AFTER=$(git -C "${SRC_DIR}/${DRIVER_NAME}" rev-parse HEAD 2>/dev/null)

log ""
echo -e "\e[1;36m==========================================================================\e[0m"
log "Driver version"
echo -e "\e[1;36m==========================================================================\e[0m"
log "  previous:   ${DRIVER_VERSION_BEFORE:-none}"
if [ -n "$DRIVER_VERSION_AFTER" ]; then
    log "  installed:  ${DRIVER_VERSION_AFTER}"
    if [ -z "$DRIVER_VERSION_BEFORE" ]; then
        log "  result:     driver installed at ${DRIVER_REV_AFTER}"
    elif [ "$DRIVER_SHA_BEFORE" = "$DRIVER_SHA_AFTER" ]; then
        log "  result:     unchanged; the car was already on ${DRIVER_REV_AFTER}"
    else
        log "  result:     updated ${DRIVER_REV_BEFORE} -> ${DRIVER_REV_AFTER}"
    fi
elif [ "$DRY_RUN" = true ]; then
    log "  installed:  not cloned (dry run)"
else
    log "  installed:  none; the clone did not complete"
fi

# ============================================================================
# Post-install state and diagnostics
#
# The second snapshot runs before the checks so the diff describes the car the
# diagnostics are about to inspect. One check per component the driver setup
# installs, so a failed run names the phase to re-run instead of just reporting
# that something went wrong.
# ============================================================================
log ""
log "Recording system state after the run..."
snapshot_state "after" "$AFTER_STATE"
diff_state

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

# Conditions the installer cannot control, such as unplugged hardware.
# Reported, but they do not fail the run.
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
    DRIVER_REV="$DRIVER_REV_AFTER"
    check_pass "${DRIVER_NAME} cloned (${DRIVER_VERSION_AFTER:-unknown revision})"
else
    check_fail "${DRIVER_NAME} not cloned into ${SRC_DIR}"
fi

# The clone should land on the revision preflight advertised. A mismatch means
# the branch moved mid-run, so the car is not on the version the operator saw.
if [ -z "$DRIVER_REMOTE_HEAD" ]; then
    : # dry run, or the remote was never queried
elif [ -z "$DRIVER_SHA_AFTER" ]; then
    check_fail "driver revision unverifiable; expected ${DRIVER_REMOTE_SHORT}"
elif [ "$DRIVER_SHA_AFTER" = "$DRIVER_REMOTE_HEAD" ]; then
    check_pass "driver is at the revision advertised before the run (${DRIVER_REMOTE_SHORT})"
else
    check_warn "driver landed on ${DRIVER_REV_AFTER}, not the ${DRIVER_REMOTE_SHORT} advertised at preflight (the branch moved mid-run)"
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
echo -e "  Installer:        \e[1mv${INSTALLER_VERSION}\e[0m"
echo -e "  Driver:           \e[1m${DRIVER_NAME} ${DRIVER_REV:-not cloned}\e[0m (was ${DRIVER_REV_BEFORE:-none})"
echo -e "  Workspace:        \e[1m${WS_DIR}\e[0m"
echo -e "  Checks:           \e[1m${PASS}/${TOTAL} passed, ${WARN} warning(s)\e[0m"
echo -e "  Log file:         \e[1m${LOG_FILE}\e[0m"
echo -e "  Duration:         \e[1m${INSTALL_MINUTES}m ${INSTALL_SECONDS}s\e[0m"
echo -e "\e[1;36m======================================================================\e[0m"

log_silent "======================== INSTALLATION SUMMARY ========================"
log_silent "  Installer:        v${INSTALLER_VERSION}"
log_silent "  Driver:           ${DRIVER_NAME} ${DRIVER_REV:-not cloned} (was ${DRIVER_REV_BEFORE:-none})"
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
