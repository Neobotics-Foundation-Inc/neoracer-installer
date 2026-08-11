# Installer guide

Entry point for putting a Neoracer car on the latest software. Erases the car's
existing workspaces and reinstalls the ROS2 driver and everything it depends on.
Target hardware: Jetson Orin Nano, JetPack 6.x / Ubuntu 22.04 (Jammy), ROS2 Humble.

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Options](#options)
- [Run steps](#run-steps)
- [Diagnostics](#diagnostics)
- [Logs](#logs)
  - [System state](#system-state)
- [Reboot requirement](#reboot-requirement)
- [Data loss](#data-loss)
- [Troubleshooting](#troubleshooting)
- [Tests](#tests)
- [Architecture](#architecture)
- [Changelog](#changelog)

## Overview

A car arriving from a classroom, a shipment, or a half-finished install is in an
unknown software state. This installer removes that state instead of patching
it: the four car directories are deleted, recreated empty, and rebuilt from the
current driver repository. The result is the same on every car regardless of
what was on it before.

The installer does not implement the install itself. It clones
[neoracer_ros2_driver](https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver)
and runs that repository's `scripts/setup_all.sh`, which installs ROS2 Humble,
the build tools, the udev rules, the workspace build, the GPU stack, JupyterLab,
and the systemd services. What this repository adds is the clean slate around
that run, a log of every run, and a diagnostic pass that checks each installed
component afterward.

## Prerequisites

- Jetson Orin Nano running JetPack 6.x (Ubuntu 22.04, Jammy).
- An internet connection for the whole run; the driver setup downloads several
  gigabytes of apt and pip packages.
- Wall power. A run takes 30 to 60 minutes on a fresh car and must not be
  interrupted.
- An account on the car with sudo rights. Do not run the installer as root.

## Usage

```bash
cd ~
git clone https://github.com/Neobotics-Foundation-Inc/neoracer-installer.git
bash neoracer-installer/scripts/install.sh
```

The installer lists the directories it is about to erase and waits for you to
type `yes`. It then asks for your sudo password once and keeps that
authorization for the rest of the run.

Rehearse a run without touching anything:

```bash
bash neoracer-installer/scripts/install.sh --dry-run
```

Already have the repository from an earlier install? Update it first, so the
car gets the current installer:

```bash
git -C ~/neoracer-installer pull
bash ~/neoracer-installer/scripts/install.sh
```

## Options

| Option | Effect |
| ------ | ------ |
| `-y`, `--yes` | Skip the confirmation prompt. Required when running without a terminal. |
| `--dry-run` | Print every action; erase nothing, clone nothing, install nothing. Diagnostics still run and describe the car as it is now. |
| `-h`, `--help` | Print usage and exit. |

Exit status is 0 when every diagnostic passes, 1 when any fails or the run is
aborted. A `--dry-run` always exits 0.

## Run steps

1. **Removal.** `~/jupyter_ws`, `~/ros2_ws`, `~/data`, `~/logs`. Core services
   are stopped first so removal does not race a running node. Each path is
   removed on its own and only if it resolves inside `$HOME`.
2. **Folder creation.** `~/ros2_ws/src`, `~/data`, `~/logs`. `~/jupyter_ws` is
   recreated later by the driver's JupyterLab phase.
3. **Driver clone and setup.** Clone the driver into `~/ros2_ws/src` and run
   `neoracer_ros2_driver/scripts/setup_all.sh`, whose eight phases are ROS2
   Humble, dev tools, user environment, udev rules, workspace build, GPU stack,
   JupyterLab, and systemd services. This is the long step.

Preflight checks run before step 1: sudo rights, the presence of `git` and
`curl`, and a reachability probe of the driver repository. A car that cannot
reach GitHub is stopped with its old software still intact.

## Diagnostics

Once the driver setup returns, the installer verifies each component, grouped by
the step and driver phase that installs it, so a failure names the script to
re-run:

- Workspace layout: the four directories exist.
- Driver checkout: the clone is present and carries `setup_all.sh`.
- ROS2 and dev tools: `/opt/ros/humble`, the `ros2` command, the driver's ROS
  packages, `colcon` / `cmake` / `rosdep`.
- User environment: both `~/.bashrc` blocks, `racecar-tool.sh`, `dialout` and
  `video` group membership.
- udev rules: `99-racecar.rules`, plus the `/dev/osrbot_*` symlinks.
- Workspace build: `install/setup.bash`, the `neoracer_ros2_driver` and
  `lakibeam1` packages, and driver visibility to `ros2 pkg list`.
- GPU stack: `torch` with CUDA available, `tensorrt`, `ultralytics`.
- JupyterLab: the `jupyter` binary, the student library and labs, the
  `racecar_student.pth` path file, and an `import racecar_core`.
- Services: the four core units installed and enabled at boot.
- Run log: no command in the run exited non-zero.

Results print as `[PASS]`, `[FAIL]`, or `[WARN]`. Warnings cover conditions the
installer does not control; a `/dev/osrbot_*` symlink is missing whenever the
device is unplugged or has not been re-plugged since the rules were installed.
Warnings do not fail the run.

## Logs

Every run writes one timestamped file to `neoracer-installer/logs/`:

```
logs/install_2026-08-10_14-32-07.log
```

The file holds every command the run executed and its output, each removal and
its resolved path, all diagnostic verdicts, the summary, and a full system-state
snapshot taken before and after the run. Nothing is rotated or overwritten, so a
car carries the history of every install it has had. Send this file along with
any bug report.

### System state

Two snapshots are recorded as `key=value` lines, one before anything is erased
and one after the driver setup returns, followed by a diff of what the run
changed:

```bash
grep '\[STATE:before\]' logs/install_2026-08-10_14-32-07.log   # the car as it arrived
grep '\[STATE:after\]'  logs/install_2026-08-10_14-32-07.log   # the car as it left
grep '\[STATE:diff\]'   logs/install_2026-08-10_14-32-07.log   # what changed
```

Each snapshot covers:

- **Device identity.** Device-tree model and board serial, `machine-id`, boot
  id, hostname, power mode. These name the individual car.
- **Platform.** Ubuntu release, kernel, L4T and JetPack versions, the flashed
  vendor image name, CUDA point release, python3 version.
- **Network.** MAC address, link state, and IPv4 address of every interface,
  plus the default route and Wi-Fi SSID. The MAC is the fallback identifier
  when a board serial is unreadable.
- **Storage and peripherals.** Disk model, serial, and size; USB device list;
  the `/dev/osrbot_*` symlink targets and video nodes.
- **Software.** ROS and colcon package versions, and the versions of torch,
  torchvision, numpy, ultralytics, onnx, tensorrt, jupyterlab, opencv, pytest.
- **Workspace and services.** Installer and driver revisions, whether the driver
  checkout is dirty, the pinned lidar tag, the installed package count, the size
  of each car directory, and the enable and active state of the four units.

The identifiers collected are device identifiers, and they stay in the local log
file. Nothing reads credentials, key material, or Wi-Fi secrets.

The diff is what makes a support request answerable: it shows the package
versions that moved, the disk the install consumed, the driver revision the car
landed on, and any peripheral that disappeared between the start and end of the
run. A run that is declined at the confirmation prompt still records the "before"
snapshot, so a car can be described without reinstalling it.

The car's own runtime log directory, `~/logs`, is separate and is one of the
directories step 1 erases.

## Reboot requirement

Reboot when the run finishes:

```bash
sudo reboot
```

Group membership from the driver's user-environment phase, the udev symlinks,
and the enabled services only take effect on the next boot. Skipping the reboot
leaves the car unable to open its serial devices.

## Data loss

Step 1 deletes student notebooks in `~/jupyter_ws`, recordings and datasets in
`~/data`, and runtime logs in `~/logs`. Copy anything worth keeping off the car
before starting. The installer prints the size of each directory at the
confirmation prompt.

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `Cannot reach the driver repository` | No internet, or GitHub is blocked. Nothing was erased; fix the connection and re-run. |
| `Do not run this installer as root` | Started with `sudo`. Re-run as the car's normal user; it escalates on its own. |
| `No terminal available to confirm the erase` | Started from a script or an ssh command without a tty. Re-run with `-y`. |
| Setup fails partway | Re-run the installer. Every phase is idempotent, so a second run is safe. |
| A single phase fails | Re-run just that phase, for example `bash ~/ros2_ws/src/neoracer_ros2_driver/scripts/setup_ml.sh`. The diagnostic names the script. |
| `/dev/osrbot_*` warnings | Unplug and re-plug the device, or reboot. The rules are installed; only the symlinks are missing. |
| `torch is installed but CUDA is unavailable` | A CPU-only wheel was installed. Re-run `setup_ml.sh` on a Jetson with JetPack CUDA present. |

## Tests

```bash
pytest
```

The suite exercises the installer through `--dry-run` against a sandbox `$HOME`
and checks the guards that only fire on a real run by reading the script source.
It never erases anything or installs ROS2.

## Architecture

See [architecture.md](architecture.md).

## Changelog

Latest entries; full history in [changelog.md](changelog.md).

### [0.2.0] - 2026-08-10
- Added: system-state snapshots before and after the run, logged as `[STATE:before]`, `[STATE:after]`, and `[STATE:diff]`.
- Added: device, platform, network, storage, peripheral, package, workspace, and service facts in every snapshot.
- Changed: `README.md` cut down to the install path; this guide holds the full reference.

### [0.1.0] - 2026-08-10
- Added: `scripts/install.sh`, the erase-and-reinstall run with preflight checks, per-run logging, and post-install diagnostics.
- Added: pytest suite covering the dry-run path and the removal guards.
- Added: repository documentation and log directory.
