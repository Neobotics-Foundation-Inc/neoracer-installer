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
| `scripts/install.sh`     | Preflight, confirmation, three run steps, diagnostics, summary         | git, curl, sudo, systemctl          |
| `capture_state` (same)   | One `key=value` line per fact; snapshotted before and after, then diffed | lsblk, lsusb, ip, dpkg, python3   |
| `logs/`                  | One timestamped log per run, never rotated                            | written by `install.sh`             |
| `tests/test_install.py`  | Dry-run behavior and guard coverage                                   | pytest, bash                        |
| `neoracer_ros2_driver`   | The actual install, in eight phases behind `scripts/setup_all.sh`     | cloned into `~/ros2_ws/src` at run  |

## Run pipeline

```
preflight (root, tools, state snapshot "before", repo reachable, sudo)
   |
   v
confirmation  ---- declined ----> exit 1, nothing removed
                                  (the "before" snapshot is kept)
   |
   v
[1/3] remove  ~/jupyter_ws  ~/ros2_ws  ~/data  ~/logs
   |
   v
[2/3] create  ~/ros2_ws/src  ~/data  ~/logs
   |
   v
[3/3] clone neoracer_ros2_driver -> bash scripts/setup_all.sh
          |
          +-> [1/8] ROS2 Humble      [5/8] workspace build
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

- **Filesystem.** Erases and recreates `~/jupyter_ws`, `~/ros2_ws`, `~/data`,
  `~/logs`. Writes `logs/install_<timestamp>.log` inside this repository.
- **Network.** `git ls-remote` and `git clone` against the driver repository.
  Everything else is fetched by the driver's setup scripts.
- **systemd.** Stops the four core units before removal; reads their enable
  state during diagnostics. Never starts them, so nothing launches mid-install.
- **sudo.** Authenticated once in preflight and refreshed by a background
  keepalive for the length of the run; the keepalive is killed on exit.
- **State sources.** `/proc/device-tree` (model, board serial, compatible),
  `/etc/machine-id`, `/etc/nv_tegra_release`, `/sys/class/net/*/address`,
  `lsblk`, `lsusb`, `ip`, `dpkg-query`, and `importlib.metadata`. All read-only.
  Device identifiers are collected; credentials and Wi-Fi secrets are not.

## Design constraints

- **Ordering.** Every abort condition is checked before step 1. A car left with
  no software because a preflight failure surfaced late is worse than a car
  that never started.
- **Removal safety.** `remove_path` deletes one explicit path per call, resolves
  symlinks first, and refuses `/`, `$HOME`, and anything outside `$HOME`.
  Step 1 stops the services holding those directories open first.
- **Idempotence.** Both this script and the driver's setup scripts are safe to
  re-run. A failed install is recovered by running the installer again, not by
  repairing state by hand.
- **Diagnostic granularity.** One check per installed component, grouped by the
  driver phase that installs it, so a failure points at a specific script to
  re-run. Conditions outside the installer's control, such as unplugged
  hardware, are warnings rather than failures.
- **Failure visibility.** The run continues to diagnostics even when the driver
  setup exits non-zero, so the operator sees exactly which components landed.
- **State fidelity.** A fact that cannot be read is recorded as `unknown` rather
  than omitted, so a key missing from the diff means the fact itself changed and
  not that the probe failed. `host.uptime_s` is excluded from the diff because
  it always moves; disk and directory sizes are kept because their movement is
  the install's footprint.
