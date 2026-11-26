# Installer guide

Entry point for putting a Neoracer car on the current software from a clean
slate. Erases the car's software folders and reinstalls the ROS2 driver and
everything it depends on. Installer 0.9.x sets up a car for driver 0.9.x.
Target hardware: Jetson Orin Nano, JetPack 6.x / Ubuntu 22.04 (Jammy), ROS2 Humble.

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Options](#options)
- [Run steps](#run-steps)
  - [Driver version reporting](#driver-version-reporting)
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
it: three car folders (`~/jupyter_ws`, `~/ros2_ws`, `~/logs`) are deleted,
recreated empty, and rebuilt from the driver repository. The result is the same
on every car regardless of what was on it before. The car's data root
`~/neoracer_data` and its profile `~/.config/racecar` are kept.

A car that already runs the driver does not need the installer. `racecar update`
pulls the latest driver, runs the same setup, and keeps the lab dashboard tuning
and camlabel images that the erase here destroys. The installer is for a newly
flashed card or a car whose driver folder is broken.

The installer does not implement the install itself. It clones
[neoracer_ros2_driver](https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver)
and runs that repository's `scripts/setup_all.sh`, which installs ROS2 Humble,
the build tools, the user environment, the udev rules, the workspace build with
the car-profile migration, the GPU stack, JupyterLab with the student library,
and the systemd services. What this repository adds is the clean slate around
that run, a log of every run, and a diagnostic pass that checks each installed
component afterward.

## Prerequisites

- Jetson Orin Nano running JetPack 6.x (Ubuntu 22.04, Jammy).
- An internet connection for the whole run; the driver setup downloads several
  gigabytes of apt and pip packages.
- Wall power. A run takes 30 to 60 minutes on a fresh car and must not be
  interrupted.
- The `racecar` account, with sudo rights. The driver's units, sudo rules and
  setup are written for that user and `/home/racecar`; on any other account
  the installer stops before erasing anything. Do not run the installer as root.

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

Environment variables:

| Variable | Effect |
| -------- | ------ |
| `DRIVER_REF` | Branch or tag of the driver to clone instead of the default branch, to test an unreleased revision on a car. Preflight resolves it before the erase; a name the repository does not have stops the run. The clone keeps every branch, so `racecar update` reaches `main` afterwards. Example: `DRIVER_REF=port/mit-0.9.0 bash neoracer-installer/scripts/install.sh`. |
| `DRIVER_URL` | Another driver repository, such as a fork. |

## Run steps

1. **Removal.** `~/jupyter_ws`, `~/ros2_ws`, `~/logs`. Every running
   `neoracer-*` unit and the vendor `jupyterlab.service` are stopped first so
   removal does not race a running node. Each path is removed on its own and
   only if it resolves inside `$HOME`. `~/neoracer_data`, `~/.config/racecar`
   and `~/osracer_ws` are not touched.
2. **Folder creation.** `~/ros2_ws/src`, `~/logs`. `~/jupyter_ws` is recreated
   later by the driver's JupyterLab phase.
3. **Driver clone and setup.** Clone the driver into `~/ros2_ws/src` and run
   `neoracer_ros2_driver/scripts/setup_all.sh`, whose eight phases are ROS2
   Humble, dev tools, user environment, udev rules, workspace build (followed
   by the move of per-car files into the car profile), GPU stack, JupyterLab
   with the student library, and systemd services. This is the long step.

Preflight checks run before step 1: not root, the `racecar` account with home
`/home/racecar`, the presence of `git` and `curl`, a reachability probe of the
driver repository, the `DRIVER_REF` lookup when it is set, and sudo. A car that
fails any of them is stopped with its old software still intact.

### Driver version reporting

The driver revision is reported twice. Before the confirmation prompt, the
installer prints the revision of the checkout it is about to delete and the
revision the clone will land on, read from the remote with `git ls-remote`
without cloning anything:

```
Driver version
  installed:  00d2993 (2026-10-27) Merge pull request #22 from Neobotics-Foundation-Inc/fix/apt
  incoming:   f21ff52 (port/mit-0.9.0, set by DRIVER_REF)
  status:     update available (00d2993 -> f21ff52)
```

The label after the incoming revision reads `remote HEAD` on a normal run. With
`DRIVER_REF` set it names the branch or tag, as above. `status` reads `first
install` when no checkout is present, and `already at the newest revision` when
the car is current, in which case the run still rebuilds from scratch. After the
driver setup returns, the same block reports `previous`, `installed`, and a
`result` line naming the transition.

Each revision line carries the short SHA, the exact tag when HEAD sits on one,
the commit date, and the commit subject. Revisions are compared as full SHAs;
the short forms are for display only, since `git rev-parse --short` widens
whenever a prefix is ambiguous.

A diagnostic confirms the clone landed on the revision preflight advertised. A
mismatch is a warning rather than a failure: it means the branch moved between
preflight and the clone, so the car is on a newer revision than the one the
operator saw. The state snapshots carry the same facts as
`ws.driver_version`, `ws.driver_rev`, `ws.driver_branch`, and
`ws.driver_commit_date`, so the diff shows the revision change on its own.

## Diagnostics

Once the driver setup returns, the installer verifies each component, grouped by
the step and driver phase that installs it, so a failure names the script to
re-run:

- Workspace layout: `~/ros2_ws/src` and `~/logs` exist, and the driver setup
  recreated `~/jupyter_ws`.
- Driver checkout: the clone is present, carries `setup_all.sh`, landed on the
  revision preflight advertised, and its `package.xml` version shares the
  installer's major.minor (installer 0.9.x for driver 0.9.x).
- ROS2 and dev tools: `/opt/ros/humble`, the `ros2` command, the ten driver ROS
  packages (ackermann messages, cv-bridge, the Foxglove bridge, slam-toolbox,
  the Nav2 map server, AMCL and lifecycle manager, robot-state-publisher,
  xacro, mcap bag storage), `colcon` / `cmake` / `rosdep`.
- User environment: both `~/.bashrc` blocks, `racecar-tool.sh`, `dialout` and
  `video` group membership.
- udev rules: `99-racecar.rules`, plus the `/dev/osrbot_*` symlinks.
- Workspace build: `install/setup.bash`, the `neoracer_ros2_driver` and
  `lakibeam1` packages, and driver visibility to `ros2 pkg list`.
- GPU stack: `torch` with CUDA available, `tensorrt`, `ultralytics`.
- JupyterLab: the `jupyter` binary, the student library and labs, the
  `racecar_student.pth` path file, an `import racecar_core`, the data root
  `~/neoracer_data`, and the `~/jupyter_ws/data` and `~/jupyter_ws/maps` links
  into it.
- Services: six units installed and enabled at boot (`teleop`, `watchdog`,
  `dashboard`, `jupyter`, `data`, `mapview`); `autonomy` and the seven lab
  dashboard units (`camlabel`, `wallfollow`, `pursuit`, `eps`, `smartfollow`,
  `linefollow`, `webteleop`) installed and not enabled; the vendor
  `jupyterlab.service` not enabled; `/etc/sudoers.d/neoracer` as mode 440 owned
  by root, read with the sudo password cached at preflight;
  `/etc/profile.d/neoracer-data.sh`.
- Run log: no command in the run exited non-zero.

Results print as `[PASS]`, `[FAIL]`, or `[WARN]`. Warnings cover conditions the
installer does not control; a `/dev/osrbot_*` symlink is missing whenever the
device is unplugged or has not been re-plugged since the rules were installed.
Warnings do not fail the run. A healthy car with every device plugged in passes
53 checks. In a dry run the sudoers file is a warning, because a dry run never
asks for a password.

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
- **Workspace and services.** Installer and driver revisions, the driver's
  `package.xml` version, whether the driver checkout is dirty, the pinned lidar
  tag, the installed package count, the size of each erased folder and of the
  data root, and the enable and active state of all fourteen units.

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

Step 1 deletes student notebooks in `~/jupyter_ws`, the driver checkout in
`~/ros2_ws` with the tuning saved inside old lab dashboard checkouts, and
runtime logs in `~/logs`. Copy anything worth keeping off the car before
starting. The installer prints the size of each folder at the confirmation
prompt.

Kept: `~/neoracer_data` (bags, maps, datasets, dashboard logs),
`~/.config/racecar` (the car profile) and `~/osracer_ws` (the vendor
workspace). A car that already runs the driver keeps everything, tuning
included, with `racecar update`.

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `Cannot reach the driver repository` | No internet, or GitHub is blocked. Nothing was erased; fix the connection and re-run. |
| `Do not run this installer as root` | Started with `sudo`. Re-run as the car's normal user; it escalates on its own. |
| `This installer runs as the racecar user` | Started from another account. The driver's services and sudo rules are written for `racecar`. Log in as `racecar` and re-run; nothing was erased. |
| `No branch or tag named ...` | `DRIVER_REF` names something the driver repository does not have. Check the spelling, or unset it for the default branch. Nothing was erased. |
| `driver X does not match installer Y` | The driver on the default branch is another release than this installer is written for. Update the installer clone (`git -C ~/neoracer-installer pull`), or set `DRIVER_REF` to the matching release. |
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

### [0.9.0] - 2026-11-26
- Added: preflight check for the `racecar` account before the erase; `DRIVER_REF` and `DRIVER_URL`; diagnostics for everything driver 0.9.0 installs and for the driver release matching the installer; snapshots of all fourteen units and the driver's package version; a confirmation prompt that names what is kept and points to `racecar update`.
- Changed: the version follows the driver release (0.9.0 for driver 0.9.0); the docs describe the 0.9.0 car.
- Removed: `~/data` is no longer erased or created.

### [0.2.2] - 2026-10-26
- Changed: README notes the `Unable to fetch some archives` failure during the ROS2 Humble install and its fix (`sudo apt-get update`, then run the installer again).
- Fixed: every running or restarting `neoracer-*` service and the vendor `jupyterlab.service` are stopped before the erase, not only the four core units.

### [0.2.1] - 2026-08-10
- Added: driver revision reported before the erase (installed vs incoming remote HEAD) and again after the setup (previous vs installed).
- Added: diagnostic confirming the clone landed on the revision advertised at preflight.

### [0.2.0] - 2026-08-10
- Added: system-state snapshots before and after the run, logged as `[STATE:before]`, `[STATE:after]`, and `[STATE:diff]`.
- Added: device, platform, network, storage, peripheral, package, workspace, and service facts in every snapshot.
- Changed: `README.md` cut down to the install path; this guide holds the full reference.

### [0.1.0] - 2026-08-10
- Added: `scripts/install.sh`, the erase-and-reinstall run with preflight checks, per-run logging, and post-install diagnostics.
- Added: pytest suite covering the dry-run path and the removal guards.
- Added: repository documentation and log directory.
