# Changelog

All notable changes to this project. Format: Keep a Changelog
(keepachangelog.com). Versioning: from 0.9.0 the installer's version follows
the driver release it installs; installer 0.9.x sets up a car for driver 0.9.x.
Earlier entries numbered the installer on its own.

## [Unreleased]

### Added
### Changed
### Fixed
### Removed

## [0.9.0] - 2026-11-26

### Added
- Preflight check that the run is the `racecar` user with home `/home/racecar`, before anything is erased. Driver 0.9.0's `setup_all.sh` stops on any other account, which used to leave an erased car with nothing rebuilt. A dry run reports the check and continues.
- `DRIVER_REF`: a branch or tag of the driver to clone instead of the default branch, to install an unreleased revision on a test car. Preflight resolves it before the erase and stops the run when it does not exist. `DRIVER_URL` names another repository, such as a fork. The clone keeps every branch, so `racecar update` still reaches `main` afterwards.
- Diagnostic that the driver's `package.xml` version shares the installer's major.minor, so a car on another release is reported in one line.
- Diagnostics for what driver 0.9.0 installs: the seven ROS packages added for mapping and navigation (slam-toolbox, nav2-map-server, nav2-amcl, nav2-lifecycle-manager, robot-state-publisher, xacro, rosbag2-storage-mcap); the data root `~/neoracer_data` and the `~/jupyter_ws/data` and `~/jupyter_ws/maps` links into it; `neoracer-data` and `neoracer-mapview` enabled at boot beside the four core units; `neoracer-autonomy` and the seven lab dashboard units installed and not enabled; the vendor `jupyterlab.service` not enabled; `/etc/sudoers.d/neoracer` as mode 440 owned by root, read through sudo; `/etc/profile.d/neoracer-data.sh`. A healthy car passes 53 checks.
- Snapshots record `ws.driver_pkg_version`, the size of the data root, and the enable and active state of all fourteen units.
- The confirmation prompt names what is kept (`~/neoracer_data`, `~/.config/racecar`, `~/osracer_ws`), warns that the tuning inside old lab dashboard checkouts under `~/ros2_ws` is erased, and points a car that already runs the driver to `racecar update`.

### Changed
- Version numbering: 0.9.0 follows driver 0.9.0. The number says which driver release the installer installs and checks.
- A core unit counts as enabled only when `systemctl is-enabled` says `enabled`; a unit with no `[Install]` section no longer passes that check.
- README, guide and architecture page describe the 0.9.0 car: six units at boot, the apps page on port 8080, the map viewer on port 8088, the data root, the `racecar` account, and `racecar update` for a car that already runs the driver.

### Removed
- `~/data` is no longer erased or created. Driver 0.9.0 writes nothing there, and its setup moves an older car's camlabel images from `~/data/camlabel` into the data root, which the erase used to destroy first. The erase list is `~/jupyter_ws`, `~/ros2_ws` and `~/logs`.

## [0.2.2] - 2026-10-26

### Changed
- README: what to do when the ROS2 Humble install stops with `Unable to fetch some archives` (the Jetson's package lists are out of date): run `sudo apt-get update`, then the installer again.

### Fixed
- Before the erase, every running or restarting `neoracer-*.service` (the lab dashboards and autonomy, not only the four core units) and the vendor image's `jupyterlab.service` are stopped. A running one had its files erased underneath it.

## [0.2.1] - 2026-08-10

### Added
- Driver version reporting: the installed revision and the incoming remote HEAD are shown before the confirmation prompt, and the previous / installed / result transition is shown once the driver is in place.
- Revision lines carry the short SHA, exact tag, commit date, and commit subject; `ws.driver_version`, `ws.driver_branch`, and `ws.driver_commit_date` join the state snapshots.
- Diagnostic confirming the clone landed on the revision advertised at preflight, warning when the branch moved mid-run.

### Changed
- Preflight resolves the driver's remote HEAD with `git ls-remote`, which also serves as the reachability probe; revisions are compared as full SHAs rather than short forms.

### Fixed
### Removed

## [0.2.0] - 2026-08-10

### Added
- System-state capture: `key=value` snapshots logged as `[STATE:before]` and `[STATE:after]`, plus a `[STATE:diff]` block listing every key the run changed.
- Captured facts: device-tree model and board serial, `machine-id`, boot id, hostname, power mode, L4T / JetPack / CUDA versions, flashed vendor image name, per-interface MAC and IPv4 and link state, default route and SSID, disk model / serial / size, USB device list, `/dev/osrbot_*` targets, ROS and Python package versions, driver and lidar revisions, per-directory sizes, and service enable and active state.
- Tests covering the snapshot markers, the captured identifiers, MAC capture, snapshot ordering ahead of removal, and temp-file cleanup.
- `INSTALLER_VERSION` stamped into the log header, the installation summary, and the state snapshots as `ws.installer_version`.

### Changed
- `README.md` reduced to what the repository is, prerequisites, installation, expected result, and where to send logs; the full guide moved to `docs/installer-guide.md`.
- The "before" snapshot is taken ahead of the confirmation prompt, so a declined run still records what the car was.
- Temp-file and sudo-keepalive teardown moved into a single `cleanup` EXIT trap.

### Fixed
### Removed

## [0.1.0] - 2026-08-10

### Added
- `scripts/install.sh`: three-step erase-and-reinstall run (remove the four car directories, recreate them, clone `neoracer_ros2_driver` and run its `setup_all.sh`).
- Preflight checks ahead of any removal: root refusal, required tools, driver-repository reachability, sudo authentication with a keepalive for the run.
- Confirmation prompt listing each directory and its size, with `-y` for non-interactive runs and `--dry-run` for a rehearsal.
- Removal guard: one explicit path per call, symlinks resolved, `/` and `$HOME` and anything outside `$HOME` refused; core services stopped before removal.
- Post-install diagnostics covering the workspace layout, driver checkout, and all eight driver phases, with `[PASS]` / `[FAIL]` / `[WARN]` verdicts and a summary.
- Per-run logging to `logs/install_<timestamp>.log`, carrying system info, every command and its output, and all diagnostic verdicts.
- Reboot notice explaining why group membership, udev symlinks, and services need a boot to take effect.
- pytest suite covering the dry-run path, log behavior, diagnostic coverage, and the removal guards.
- `README.md`, `docs/architecture.md`, and this changelog.
