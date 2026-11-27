# neoracer-installer

This is the entry point for putting a Neoracer car on the current software from a
clean slate. Everything runs from one script, `scripts/install.sh`. The script
erases the car's software folders and reinstalls the ROS2 driver and everything it
depends on. Before the erase, you choose whether `~/jupyter_ws`, with the students'
notebooks, is kept. For more information on the driver, see [neoracer_ros2_driver](https://github.com/Neobotics-Foundation-Inc/neoracer_ros2_driver/tree/main).

Installer 0.9.x sets up a car for driver 0.9.x. The two share a version number.

For Jetson Orin Nano and Orin NX running JetPack 6.x (Ubuntu 22.04) with ROS2 Humble.

## Table of contents

- [Which to use](#which-to-use)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Expected result](#expected-result)
- [Troubleshooting](#troubleshooting)
- [Documentation](#documentation)

## Which to use

- A car that already runs the Neoracer driver: run `racecar update` on the car.
  It pulls the latest driver, runs its setup, and keeps the car's data, maps,
  settings and lab dashboard tuning.
- A newly flashed card, or a car whose driver folder is broken: run this
  installer. It erases the software folders and rebuilds them.

## Prerequisites

- A Jetson Orin Nano or Orin NX flashed with JetPack 6.x (Ubuntu 22.04, Jammy).
- An internet connection for the whole run; several gigabytes are downloaded.
- Wall power and 30 to 60 uninterrupted minutes.
- The `racecar` account, with sudo rights. The driver's services run as that
  user, and the installer stops before erasing anything on any other account.
  Do not run the installer as root.
- A backup of anything you care about. The install erases `~/ros2_ws` and
  `~/logs`, including the tuning saved inside old lab dashboard checkouts under
  `~/ros2_ws`. It erases `~/jupyter_ws` only when you choose to reinstall
  everything, and it first moves that folder to a dated backup. It keeps
  `~/neoracer_data` (bags, maps, datasets), `~/.config/racecar` (the car
  profile) and `~/osracer_ws`.

## Installation

1. `cd` into your home folder:

    ```bash
    cd ~
    ```

2. Clone the installer:

    ```bash
    git clone https://github.com/Neobotics-Foundation-Inc/neoracer-installer.git
    ```

3. Run the installer:

    ```bash
    bash neoracer-installer/scripts/install.sh
    ```

    - Enter your sudo password once when prompted
    - Choose what to reinstall:

      ```
      What should this run reinstall?
        1) The driver and the student library. ~/jupyter_ws remains.
        2) Everything. ~/jupyter_ws is erased too, and the newest labs are installed.
      Choose 1 or 2 [1]:
      ```

      Choice 1, or Enter, keeps the notebooks and labs in `~/jupyter_ws` as
      they are. Choice 2 moves `~/jupyter_ws` to a dated folder such as
      `~/jupyter_ws-backup-20261127-141500` and installs the newest labs. The
      backup stays until you delete it. JupyterLab shows only `~/jupyter_ws`,
      so copy a notebook back from the backup in a terminal.
    - Review the directories it lists and type `yes` to confirm the erase.
      Both choices set the car's services back to their defaults. A service
      you turned off starts at boot again, and a lab dashboard you set to
      start at boot stays off until you enable it again.
    - Wait 30 to 60 minutes while the driver, ROS2, and the GPU stack install
    - If the ROS2 Humble install stops with `Unable to fetch some archives`,
      the Jetson's package lists are out of date. Run `sudo apt-get update`,
      then run the installer again.

4. Reboot when the script tells you to. Group membership, udev symlinks, and
   the car's services only take effect on the next boot.

    ```bash
    sudo reboot
    ```

To see what the installer would do without changing anything, run it with the
`--dry-run` flag first. It shows the same menu and prints the plan for your
choice:

```bash
bash neoracer-installer/scripts/install.sh --dry-run
```

With the `-y` flag, the run reinstalls everything (choice 2) with no menu and no
confirmation.

## Expected result

The run prints three steps, then checks every component it installed:

```
[1/3] Removing existing systems and code...
[2/3] Creating workspace folders...
[3/3] Cloning the driver and running its setup...

Running post-install diagnostics...
  [PASS] driver 0.9.0 matches installer 0.9.0 (release 0.9)
  [PASS] ROS2 Humble installed (/opt/ros/humble)
  [PASS] workspace built (/home/racecar/ros2_ws/install/setup.bash)
  ...
  All 53 checks passed.
```

The driver revision the car is on before the run, and the one it will be moved
to, are both shown before you confirm the erase, and again once the driver is in
place.

The summary at the end follows your choice. After choice 1 it reads
`Labs: kept as they were. Run 'racecar update --labs' to refresh them.` On a
car with no labs yet, it reads
`Labs: none to keep. The driver setup installs the newest labs.` After choice 2
it names the backup folder.

After the reboot you have a built `~/ros2_ws`, the `racecar` command in every new
terminal, JupyterLab on port 8888, the apps page on port 8080, the map viewer on
port 8088, and the teleop stack starting automatically at boot.

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
