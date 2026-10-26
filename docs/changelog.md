# Changelog

All notable changes to this project. Format: Keep a Changelog
(keepachangelog.com). Versioning: Semantic Versioning (semver.org).

## [Unreleased]

### Added
### Changed
### Fixed
### Removed

## [0.2.2] - 2026-10-26

### Changed
- README: what to do when the ROS2 Humble install stops with `Unable to fetch some archives` (the Jetson's package lists are out of date): run `sudo apt-get update`, then the installer again.

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
