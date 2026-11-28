# Installer guide

Entry point for putting a Neoracer car on the current software from a clean
slate. Erases the car's software folders and reinstalls the ROS2 driver and
everything it depends on. Installer 0.9.x sets up a car for driver 0.9.x.
Target hardware: Jetson Orin Nano, JetPack 6.x / Ubuntu 22.04 (Jammy), ROS2 Humble.

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
  - [Reinstall choice](#reinstall-choice)
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
it: the car folders `~/ros2_ws` and `~/logs` are deleted, recreated empty, and
rebuilt from the driver repository. The result is the same on every car
regardless of what was on it before. Before the erase, the operator chooses
whether `~/jupyter_ws`, the students' notebooks and labs, is kept (choice 1) or
moved to a dated backup and rebuilt too (choice 2). The car's data root
`~/neoracer_data` and its profile `~/.config/racecar` are kept in both choices.

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

You enter your sudo password once, and the run keeps that authorization to its
end. The reinstall menu comes next, then the list of directories the chosen run
erases. The erase starts only after you type `yes`.

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

### Reinstall choice

Before the warning, a run with a terminal shows this menu:

```
What should this run reinstall?
  1) The driver and the student library. ~/jupyter_ws remains.
  2) Everything. ~/jupyter_ws is erased too, and the newest labs are installed.
Choose 1 or 2 [1]:
```

Enter picks 1. Any other answer than `1`, `2` or an empty line shows the prompt
again. The log records each answer and the choice.

| | Choice 1 | Choice 2 |
| --- | --- | --- |
| Erased | `~/ros2_ws`, `~/logs` | `~/jupyter_ws`, `~/ros2_ws`, `~/logs` |
| `~/jupyter_ws` | Kept as it is, with the notebooks and labs | Moved to `~/jupyter_ws-backup-YYYYMMDD-HHMMSS`, then rebuilt by the driver setup |
| Labs | Kept as they were. `racecar update --labs` refreshes them later. | The newest labs from the driver setup |
| Services | Back to the driver's defaults | Back to the driver's defaults |

In both choices the services go back to their defaults: the core units start at
boot, and autonomy and the lab dashboards do not. A service you turned off
starts at boot again. `racecar service disable <name>` turns it off again. A lab
dashboard you set to start at boot stays off until
`racecar service enable <name>` turns it on again.

Choice 1 keeps the labs through the driver setup's `RACECAR_LABS_REFRESH`
setting, which the driver 0.9.0 release reads. A driver from before that setting,
cloned with `DRIVER_REF`, copies the shipped labs over the kept ones.

`-y` means choice 2 with no questions. Choice 1 is offered only in the menu.

## Options

| Option | Effect |
| ------ | ------ |
| `-y`, `--yes` | Reinstall everything (choice 2) with no questions. The menu and the confirmation prompt are skipped. Required when running without a terminal. |
| `--dry-run` | Print every action; erase nothing, clone nothing, install nothing. Diagnostics still run and describe the car as it is now. With a terminal and no `-y`, the menu is shown and the plan follows the choice. Without a terminal, or with `-y`, the plan is choice 2. |
| `-h`, `--help` | Print usage and exit. |

Exit status is 0 when every diagnostic passes, 1 when any fails or the run is
aborted. A `--dry-run` always exits 0.

Environment variables:

| Variable | Effect |
| -------- | ------ |
| `DRIVER_REF` | Branch or tag of the driver to clone instead of the default branch, to test an unreleased revision on a car. Preflight resolves it before the erase; a name the repository does not have stops the run. The clone keeps every branch, so `racecar update` reaches `main` afterwards. Example: `DRIVER_REF=port/mit-0.9.0 bash neoracer-installer/scripts/install.sh`. |
| `DRIVER_URL` | Another driver repository, such as a fork. |

## Run steps

1. **Removal.** This step runs in four parts.
   - Every running `neoracer-*` unit and the vendor `jupyterlab.service` are
     stopped, so removal does not race a running node.
   - In choice 2, `~/jupyter_ws` is moved to
     `~/jupyter_ws-backup-YYYYMMDD-HHMMSS` beside it. The move is a rename on
     the same disk, so it completes in full or changes nothing. A backup name
     that exists already stops the backup, so a backup never lands inside an
     older one. A failed backup ends the run before anything is erased, and
     the stopped units are started again. A missing `~/jupyter_ws` needs no
     backup. When `~/jupyter_ws` is a link, the link moves, and the folder it
     points to stays where it is.
   - Each installed `/etc/systemd/system/neoracer-*.service` is disabled and
     its unit file removed. A `neoracer-*` boot link left without its unit
     file is removed too. Then `systemctl daemon-reload` runs, all through
     sudo. `jupyterlab.service` and `/etc/sudoers.d/neoracer` are left alone.
   - `~/ros2_ws` and `~/logs` are removed. Each path is removed on its own and
     only if it resolves inside `$HOME`. `~/neoracer_data`, `~/.config/racecar`
     and `~/osracer_ws` are not touched, and neither is `~/jupyter_ws` in
     choice 1.
2. **Folder creation.** `~/ros2_ws/src`, `~/logs`. In choice 2, `~/jupyter_ws`
   is recreated later by the driver's JupyterLab phase.
3. **Driver clone and setup.** Clone the driver into `~/ros2_ws/src` and run
   `neoracer_ros2_driver/scripts/setup_all.sh`, whose eight phases are ROS2
   Humble, dev tools, user environment, udev rules, workspace build (followed
   by the move of per-car files into the car profile), GPU stack, JupyterLab
   with the student library, and systemd services. This is the long step.
   Choice 1 runs the setup with `RACECAR_LABS_REFRESH=0`, so a value exported
   in the shell cannot refresh the kept labs. The setup installs every unit as
   new, so it enables the core units at boot and leaves autonomy and the lab
   dashboards off.

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

- Workspace layout: `~/ros2_ws/src` and `~/logs` exist. `~/jupyter_ws` is
  present (choice 1) or was recreated by the driver setup (choice 2).
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

The file holds every command the run executed and its output, each menu answer
and the reinstall choice, the backup path, each removal and its resolved path,
all diagnostic verdicts, the summary, and a full system-state snapshot taken
before and after the run. Nothing is rotated or overwritten, so a
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

In both choices, step 1 deletes the driver checkout in `~/ros2_ws` with the
tuning saved inside old lab dashboard checkouts, and the runtime logs in
`~/logs`. Copy anything worth keeping off the car before starting. The
installer prints the size of each folder at the confirmation prompt.

Choice 1 keeps `~/jupyter_ws` as it is. Choice 2 moves it to
`~/jupyter_ws-backup-YYYYMMDD-HHMMSS` before the erase, and the summary names
the folder. Old backups stay until someone deletes them, so delete one when it
is no longer needed. JupyterLab shows only `~/jupyter_ws`, so copy a notebook
back from a backup in a terminal, for example
`cp ~/jupyter_ws-backup-20261127-141500/my_lab.ipynb ~/jupyter_ws/`. The
`data` and `maps` entries in a backup are links into `~/neoracer_data`.
`rm -rf` on the backup removes the links and leaves the data root as it is.

Kept: `~/neoracer_data` (bags, maps, datasets, dashboard logs),
`~/.config/racecar` (the car profile) and `~/osracer_ws` (the vendor
workspace). A car that already runs the driver keeps everything, tuning and
service settings included, with `racecar update`.

## Troubleshooting

| Symptom | Cause and fix |
| ------- | ------------- |
| `Cannot reach the driver repository` | No internet, or GitHub is blocked. Nothing was erased; fix the connection and re-run. |
| `Do not run this installer as root` | Started with `sudo`. Re-run as the car's normal user; it escalates on its own. |
| `This installer runs as the racecar user` | Started from another account. The driver's services and sudo rules are written for `racecar`. Log in as `racecar` and re-run; nothing was erased. |
| `No branch or tag named ...` | `DRIVER_REF` names something the driver repository does not have. Check the spelling, or unset it for the default branch. Nothing was erased. |
| `driver X does not match installer Y` | The driver on the default branch is another release than this installer is written for. Update the installer clone (`git -C ~/neoracer-installer pull`), or set `DRIVER_REF` to the matching release. |
| `No terminal available to confirm the erase` | Started from a script or an ssh command without a tty. Re-run with `-y`, which reinstalls everything (choice 2), or from a terminal to see the menu. |
| `No choice was made` | The menu's input ended, for example with Ctrl-D. Nothing was erased. Re-run and choose 1 or 2. |
| `The backup of /home/racecar/jupyter_ws failed` | The move to the dated backup folder failed. The line above it names the folder. A folder of that name exists already, or `~/jupyter_ws` could not be renamed, for example because it is a mount point. Nothing was erased, and the stopped services were started again. Check the log, then re-run. |
| A service I turned off starts at boot | Both choices set the services back to the driver's defaults. Turn it off again with `racecar service disable <name>`. |
| A lab dashboard no longer starts at boot | The driver's defaults leave every lab dashboard off. Turn one on again with `racecar service enable <name>`. |
| The run was stopped with Ctrl-C in step 1 | Re-run the installer. A run stopped while the services were stopping leaves them stopped until the next reboot. A run stopped after the unit files went leaves the car with no neoracer services until a run completes. |
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
- Added: preflight check for the `racecar` account before the erase; `DRIVER_REF` and `DRIVER_URL`; diagnostics for everything driver 0.9.0 installs and for the driver release matching the installer; snapshots of all fourteen units and the driver's package version; a confirmation prompt that names what is kept and points to `racecar update`; a reinstall menu, where choice 1 keeps `~/jupyter_ws` and choice 2 moves it to a dated backup before the erase; the neoracer unit files are disabled and removed before the erase, so the services go back to their defaults.
- Changed: the version follows the driver release (0.9.0 for driver 0.9.0); the docs describe the 0.9.0 car; the warning lists only what the chosen run erases; `-y` means choice 2 with no questions.
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
