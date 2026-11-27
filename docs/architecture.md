# Architecture

## Overview

A single bash script, `scripts/install.sh`, run by hand on the car. It owns the
destructive part of provisioning (erase, recreate, clone) and the verification
part (diagnostics); the installation itself belongs to the driver repository's
own setup scripts, which this script calls. No daemon, no state file: the log
directory is the only thing a run leaves behind in this repository.

## Components

| Module (path)            | Responsibility                                                        | Depends on                          |
| ------------------------ | --------------------------------------------------------------------- | ----------------------------------- |
| `scripts/install.sh`     | Preflight, reinstall menu, confirmation, three run steps, diagnostics, summary | git, curl, sudo, systemctl |
| `capture_state` (same)   | One `key=value` line per fact; snapshotted before and after, then diffed | lsblk, lsusb, ip, dpkg, python3   |
| `logs/`                  | One timestamped log per run, never rotated                            | written by `install.sh`             |
| `tests/test_install.py`  | Dry-run behavior and guard coverage                                   | pytest, bash                        |
| `neoracer_ros2_driver`   | The actual install, in eight phases behind `scripts/setup_all.sh`     | cloned into `~/ros2_ws/src` at run  |

## Run pipeline

```
preflight (root, racecar account, tools, state snapshot "before",
           repo reachable, DRIVER_REF lookup, sudo)
   |
   v
reinstall menu (a terminal and no -y; -y means choice 2)
   1) the driver and the student library; ~/jupyter_ws remains
   2) everything; ~/jupyter_ws is backed up, then erased
   |
   v
confirmation  ---- declined ----> exit 1, nothing removed
                                  (the "before" snapshot is kept)
   |
   v
[1/3] stop the running neoracer-* units and jupyterlab.service
      choice 2: move ~/jupyter_ws to ~/jupyter_ws-backup-YYYYMMDD-HHMMSS
                ---- failed ----> start the stopped units, exit 1,
                                  nothing removed
      disable and remove /etc/systemd/system/neoracer-*.service,
      systemctl daemon-reload
      remove  ~/ros2_ws  ~/logs
              (kept: ~/neoracer_data  ~/.config/racecar  ~/osracer_ws,
               and ~/jupyter_ws in choice 1)
   |
   v
[2/3] create  ~/ros2_ws/src  ~/logs
   |
   v
[3/3] clone neoracer_ros2_driver (DRIVER_REF, or the default branch)
      -> bash scripts/setup_all.sh
         (choice 1: RACECAR_LABS_REFRESH=0, so the labs stay as they are)
          |
          +-> [1/8] ROS2 Humble      [5/8] workspace build + car profile
              [2/8] dev tools        [6/8] GPU stack
              [3/8] user environment [7/8] JupyterLab + student library
              [4/8] udev rules       [8/8] systemd services
   |
   v
state snapshot "after" -> [STATE:diff] -> diagnostics -> summary
   |
   v
reboot notice -> exit 0 or 1
```

## Interfaces

- **Filesystem.** Erases and recreates `~/ros2_ws` and `~/logs`. In choice 2,
  moves `~/jupyter_ws` to `~/jupyter_ws-backup-YYYYMMDD-HHMMSS`, where it stays
  until someone deletes it, and the driver setup recreates `~/jupyter_ws`.
  Never touches `~/neoracer_data`, `~/.config/racecar` or `~/osracer_ws`.
  Writes `logs/install_<timestamp>.log` inside this repository.
- **Network.** `git ls-remote` and `git clone` against the driver repository.
  Everything else is fetched by the driver's setup scripts.
- **Environment.** `DRIVER_REF` (a branch or tag) and `DRIVER_URL` select what
  is cloned. Unset, the default branch at HEAD. In choice 1, the driver setup
  runs with `RACECAR_LABS_REFRESH=0`.
- **Terminal.** The reinstall menu and the confirmation read stdin, and only
  when it is a terminal. `-y` replaces both.
- **systemd.** Stops every running `neoracer-*` unit and the vendor
  `jupyterlab.service` before removal. Then disables each installed
  `/etc/systemd/system/neoracer-*.service`, removes its unit file and runs
  `systemctl daemon-reload`, so the driver setup installs every unit as new.
  Leaves `jupyterlab.service` and `/etc/sudoers.d/neoracer` alone. Reads the
  enable state of the fourteen 0.9.0 units during diagnostics. Starts units
  only when a failed backup ends the run before the erase, and then only the
  ones it stopped, so nothing launches mid-install.
- **sudo.** Authenticated once in preflight and refreshed by a background
  keepalive for the length of the run; the keepalive is killed on exit. The
  cached password also lets the diagnostics read `/etc/sudoers.d/neoracer`.
- **State sources.** `/proc/device-tree` (model, board serial, compatible),
  `/etc/machine-id`, `/etc/nv_tegra_release`, `/sys/class/net/*/address`,
  `lsblk`, `lsusb`, `ip`, `dpkg-query`, and `importlib.metadata`. All read-only.
  Device identifiers are collected; credentials and Wi-Fi secrets are not.

## Design constraints

- **Ordering.** Every abort condition is checked before anything is erased.
  The backup in step 1 comes before the unit files and the folders go, so a
  failed backup leaves the car as it was. A car left with no software because
  a preflight failure surfaced late is worse than a car that never started.
- **Removal safety.** `remove_path` deletes one explicit path per call, resolves
  symlinks first, and refuses `/`, `$HOME`, and anything outside `$HOME`.
  Step 1 stops the services holding those directories open first.
- **Backup.** `backup_jupyter_ws` renames `~/jupyter_ws` to a dated folder
  beside it, the scheme of the driver's labs backups. A rename on one disk
  completes in full or changes nothing. A name that exists already stops the
  backup, so a backup never lands inside an older one.
- **Idempotence.** Both this script and the driver's setup scripts are safe to
  re-run. A failed install is recovered by running the installer again, not by
  repairing state by hand.
- **Diagnostic granularity.** One check per installed component, grouped by the
  driver phase that installs it, so a failure points at a specific script to
  re-run. Conditions outside the installer's control, such as unplugged
  hardware, are warnings rather than failures.
- **Version.** The installer's version follows the driver release it installs
  (installer 0.9.x for driver 0.9.x). A diagnostic compares the two, so a car
  on another release is reported in one line instead of many failing checks.
- **Failure visibility.** The run continues to diagnostics even when the driver
  setup exits non-zero, so the operator sees exactly which components landed.
- **State fidelity.** A fact that cannot be read is recorded as `unknown` rather
  than omitted, so a key missing from the diff means the fact itself changed and
  not that the probe failed. `host.uptime_s` is excluded from the diff because
  it always moves; disk and directory sizes are kept because their movement is
  the install's footprint.
