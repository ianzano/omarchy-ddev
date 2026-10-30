# DDEV Projects for Omarchy

Native Quickshell taskbar plugin. Click the Docker icon and running/registered count beside the system tray.

![DDEV project overview with per-project controls](preview.png)

<details>
<summary>Database snapshots and live console previews</summary>

![Database snapshots and Restore buttons inside a project card](docs/previews/snapshots.png)

![Project startup progress with a spinner and inline console output](docs/previews/console.png)

![Application containers with health, live statistics, and pause controls](docs/previews/applications.png)

![Inline container log viewer with service selection](docs/previews/logs.png)

</details>

Previews render the actual plugin interface with fictional projects, paths, snapshots, and console output.

- Lists every project returned by `ddev list -j`, with live status every 15 seconds.
- Sliding start/stop switches, colored project status cards, Restart beside each power switch (enabled only for running projects), and icon shortcuts for browse, Mailpit, and the project folder.
- Filter by project name or path.
- Inspect each application's containers, health, CPU, memory, network and disk I/O, and process count.
- Pause/resume individual container processes, with controls scoped to registered DDEV projects.
- View container logs inline, switch services, and follow updates without blocking project actions.
- Receive desktop alerts for stopped, unhealthy, started, and recovered containers, even with the panel closed.
- Show local database snapshots with timestamps and sizes; create automatically named or custom named snapshots.
- Restore a selected snapshot after explicit confirmation that the current database will be replaced.
- Per-project animated spinners and elapsed time during operations. Snapshots and live stdout/stderr appear inside the corresponding project card. Each project keeps its own console output for the shell session. A compact preview shows the latest six lines; **Show all output** expands the card, using only the main panel scrollbar. Shows errors and command output. Docker connectivity errors produce an unknown status rather than a misleading stopped status.

## Install

Requires Omarchy's Quickshell bar, Python 3, DDEV, Docker, `xdg-open`, and `notify-send` (libnotify) for desktop alerts.

Install directly with Omarchy:

```sh
omarchy plugin add https://github.com/ianzano/omarchy-ddev.git --enable
```

To install from a local checkout:

```sh
git clone https://github.com/ianzano/omarchy-ddev.git
cd omarchy-ddev
python3 install.py
```

Installs to `~/.config/omarchy/plugins/ianzano.ddev/` and adds `ianzano.ddev` beside the system tray in `shell.json`. Existing config is backed up to `shell.json.bak.ddev-<timestamp>`. Existing plugin files are backed up under `~/.config/omarchy/plugin-backups/`. Shell config and plugins hot-reload.

`manifest.json`, `Panel.qml`, `backend.py`, and `Monitoring.js` live at the repository root so the repository is directly installable by Omarchy. The repository is named `omarchy-ddev`; the namespaced plugin ID and installed directory name are `ianzano.ddev`.

## Update

For installations made with `omarchy plugin add`:

```sh
omarchy plugin update ianzano.ddev
```

For manual installs, pull the repository and run `python3 install.py` again.

## Usage

**Applications** expands the service containers belonging to a registered DDEV project. Live statistics update about every three seconds while that section is open. CPU, memory usage/limit, network I/O, disk I/O, and process count come from Docker. Paused and stopped containers show unavailable statistics rather than misleading zero values. Containers without a Docker health check have no health badge.

Use **Pause** or **Resume** on a service to freeze/unfreeze its processes with Docker. This preserves the container and its memory; it is different from stopping a project. Restart is disabled while any service is paused. Other projects can still run operations concurrently.

**Logs** opens the project's web container by default; service buttons switch between containers. The viewer keeps up to 200 timestamped lines (24,000 characters), refreshing every two seconds while **Live** is selected and the panel is open. It shows both stdout and stderr. Use **Show all logs** to expand within the panel's single scroll area. Reading logs does not lock start/stop or pause/resume controls. Closing the viewer stops its refreshes.

**Container alerts** in settings toggles desktop notifications. Docker events detect stops, starts, unhealthy states, and health recovery; background inventory checks provide a fallback. Initial discovery is silent, repeated states are deduplicated across displays, and pausing/resuming does not produce stop/start alerts. The event connection retries automatically when Docker returns. Idle inventory checks run about every ten seconds; live statistics are collected only while Applications is open. Monitoring covers containers labelled `com.ddev.site-name` for registered projects; shared DDEV infrastructure and services that omit DDEV labels are excluded.


Click Snapshots on a project to expand its database controls directly inside that project’s card. Create accepts an optional name using letters, numbers, dots, underscores, and dashes. Snapshot discovery supports `.gz`, `.zst`, `.mbstream`, and `.xbstream` files, including symlinked `.ddev` directories. The list shows snapshots in the selected project's `.ddev/db_snapshots`; snapshots in other Git worktrees are not included.

The top toolbar’s power icon runs `ddev poweroff` after confirmation, stopping all DDEV projects and shared services. Its live output appears below the toolbar.

Click **Restore…** inside a snapshot card and confirm with **Restore database**. The confirmation identifies the project and snapshot. Switching projects clears the confirmation.

Restoring replaces the current database. Create a fresh snapshot first if you need to preserve it. DDEV handles database compatibility checks; the plugin never uses `--force`. DDEV may start a stopped project during database operations. Different projects can run operations concurrently, each with its own spinner, elapsed time, and output. Conflicting operations on the same project are blocked until its current command finishes. Global `ddev poweroff` is exclusive and cannot overlap project operations. Keep the shell running while commands finish. Stop runs plain `ddev stop`, without removing database volumes. Commands run as your desktop user. Missing environment variables are filled from the systemd user environment, preserving values already inherited from the desktop. If needed, the SSH agent falls back to the current user’s `ssh-agent.socket` under `XDG_RUNTIME_DIR`. Commands use argument arrays rather than shell strings, and are limited to registered projects.

Use the settings gear to adjust the refresh interval with a slider (5–60 seconds); the setting is saved in the bar configuration. Middle-click the widget to refresh. The refresh period can be configured with `refreshIntervalSec` in its bar layout entry. Console text is selectable, with the most recent 24,000 characters retained per project. There is one scroll area for the entire panel; expanded console output has no separate scrollbar. Use **Show less** to return to the latest six lines, or the chevron to collapse the console. The spinner indicates ongoing work, rather than a percentage estimate.

```sh
omarchy-shell ianzano.ddev open
omarchy-shell ianzano.ddev close
omarchy-shell ianzano.ddev refresh
omarchy-shell ianzano.ddev status
omarchy plugin validate .
python3 -m unittest -v test_backend test_install test_containers
python3 test_ui.py  # Requires the desktop Wayland session; uses simulated projects
```

## Remove

```sh
omarchy plugin remove ianzano.ddev
```

For a manual installation, remove the `ianzano.ddev` entry from the bar layout in `~/.config/omarchy/shell.json`, then delete `~/.config/omarchy/plugins/ianzano.ddev/`. Projects and snapshots are unaffected.

## Validation

Backend tests verify output arrives before a command finishes, merged stderr, Unicode, command exit codes, streaming timeouts, safe stop arguments, command failures, invalid names, unregistered projects, restore path validation, symlinked project config, and unavailable Docker status. The QML component was loaded using the installed Quickshell runtime. No live start/stop, snapshot creation, or database restore is needed for these checks.

Container tests verify Docker label scoping, pause/resume state guards, bounded logs, stats failures, and safe event parsing. Inline UI checks with simulated projects verify log viewing, pause/resume, alert transitions and deduplication, plus card ownership for snapshots and console output, live streaming, six-line previews, full expansion, and separate logs across projects.

## Local data

The repository contains source code and synthetic test fixtures. Project names, paths, environment values, database snapshots, and command output are discovered on the user's machine at runtime. The plugin has no telemetry or upload code; command output and logs remain in memory for the shell session. Lifecycle alerts are delivered through the local desktop notification daemon. Container discovery reads selected state and label fields, not container environment values. Environment variables are passed locally to child processes and are not written to the repository. Local environment files, runtime configs, logs, backups, and snapshot directories are excluded by `.gitignore`.

## License

[MIT](LICENSE) © 2026 ianzano.

## Publishing

The root manifest follows the [Omarchy publishing guide](https://plugins.omarchy.org/publish.html). Validate the repository with `omarchy plugin validate .` before submitting its URL to the marketplace. A valid repository is ready for submission; listing still requires marketplace review.

## Regenerate previews

```sh
python3 tools/render_previews.py
```

Requires the installed Omarchy shell, Quickshell, and a Nerd Font. The renderer runs headlessly with an isolated home and configuration directory. It disables backend discovery and uses synthetic data, without capturing the desktop or running DDEV commands. It writes `preview.png` for the marketplace and additional images under `docs/previews/`.
