# neoracer-installer

This is the entry point for updating software on a Neoracer to the latest version.
The system is designed to run everything from one script located in `/scripts/install.sh`.
This script deletes the car's existing workspaces and reinstalls the ROS2 driver 
and everything it depends on. For more information on the driver, see [neoracer_ros2_driver](https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver/tree/main).

For Jetson Orin Nano and Orin NX running JetPack 6.x (Ubuntu 22.04) with ROS2 Humble.

## Table of contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Expected result](#expected-result)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)

## Prerequisites

- A Jetson Orin Nano or Orin NX flashed with JetPack 6.x (Ubuntu 22.04, Jammy).
- An internet connection for the whole run; several gigabytes are downloaded.
- Wall power and 30 to 60 uninterrupted minutes.
- An account on the car with sudo rights. Do not run the installer as root.
- A backup of anything you care about. The install erases `~/jupyter_ws`,
  `~/ros2_ws`, `~/data`, and `~/logs`.

## Installation

1. `cd` into your home folder: `cd ~`
2. Run `git clone https://github.com/Neobotics-Foundation-Inc/neoracer-installer.git`
3. Run `bash neoracer-installer/scripts/install.sh`
    - Review the directories it lists and type `yes` to confirm the erase
    - Enter your sudo password once when prompted
    - Wait 30 to 60 minutes while the driver, ROS2, and the GPU stack install
4. Run `sudo reboot` when the script tells you to. Group membership, udev
   symlinks, and the car's services only take effect on the next boot.

To see what the installer would do without changing anything, run
`bash neoracer-installer/scripts/install.sh --dry-run` first.

## Expected result

The run prints three steps, then checks every component it installed:

```
Driver version
  installed:  9c6902a (v0.4.2, 2026-08-07) Merge pull request #15 from ...
  incoming:   1f4ab90 (remote HEAD)
  status:     update available (9c6902a -> 1f4ab90)

[1/3] Removing existing systems and code...
[2/3] Creating workspace folders...
[3/3] Cloning the driver and running its setup...

Driver version
  previous:   9c6902a (v0.4.2, 2026-08-07) Merge pull request #15 from ...
  installed:  1f4ab90 (v0.5.0, 2026-08-10) Add lidar scan-health watchdog
  result:     updated 9c6902a -> 1f4ab90

Running post-install diagnostics...
  [PASS] ROS2 Humble installed (/opt/ros/humble)
  [PASS] workspace built (/home/racecar/ros2_ws/install/setup.bash)
  ...
  All 36 checks passed.
```

The version the car is on before the run, and the one it will be moved to, are
both shown before you confirm the erase, and again once the driver is in place.

After the reboot you have a built `~/ros2_ws`, the `racecar` command in every new
terminal, JupyterLab on port 8888, the status dashboard on port 8080, and the
teleop stack starting automatically at boot.

A `[WARN]` line for a `/dev/osrbot_*` device means that peripheral was unplugged
or powered off during the run; plug it in and reboot. Any `[FAIL]` line names the
setup script to re-run.

## Troubleshooting

Every run writes a log to `neoracer-installer/logs/`. Send the newest one when
you ask for help:

```bash
ls -t ~/neoracer-installer/logs/install_*.log | head -1
```

That file carries every command and its output, all diagnostic results, and a
snapshot of the car's hardware and software state before and after the run,
which is usually enough to answer a question without touching the car. It
identifies the machine (board serial, MAC addresses, disk serial); it contains
no passwords or key material.

Re-running the installer is safe and should be the first thing to try after a failed
run. If this does not resolve the issue, please send the .log file of the installer
run to the developers for further inspection.

## Documentation

- [docs/installer-guide.md](docs/installer-guide.md): full guide. Options,
  every diagnostic, log contents, and troubleshooting.
- [docs/architecture.md](docs/architecture.md): how the installer is built.
- [docs/changelog.md](docs/changelog.md): release history.
