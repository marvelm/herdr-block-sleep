# herdr-block-sleep

- [herdr](https://herdr.dev) plugin for macOS that prevents sleep while agents are working.

The plugin builds one Swift binary that owns native IOKit power assertions with `IOPMAssertionCreateWithName` and implements `start`, `stop`, `status`, and `daemon`.

## Behavior

The monitor uses Herdr's local socket API:

- it bootstraps state with `agent.list`
- it subscribes to `pane.agent_status_changed` for currently known agent panes with `events.subscribe`
- when an agent-status event arrives, it refreshes agent state and updates the power assertion
- while waiting for Herdr events, it checks `AppleClamshellState` every 15 seconds so closing the lid releases the assertion promptly
- every 5 minutes it reconciles with `agent.list` to discover new/removed panes and catch missed events
- if the Herdr API fails repeatedly, it releases assertions and exits

The helper creates these assertion types:

+ `PreventUserIdleSystemSleep`
+ `PreventSystemSleep`

## Requirements

Runtime:

- macOS
- Herdr 0.7.0 or newer
- IOKit, `ioreg`, and system power-management services from macOS
- Swift compiler from Xcode or Command Line Tools (`swiftc`)

## Install from GitHub

After this repository is published, install it with Herdr:

```sh
herdr plugin install marvelm/herdr-block-sleep
```

Herdr clones the repository, runs the manifest build command, and registers the plugin:

```toml
[[build]]
command = ["swiftc", "src/main.swift", "-O", "-o", "bin/herdr-block-sleep"]
```

The startup hook starts the monitor when the Herdr server starts. To start it immediately after install:

```sh
herdr plugin action invoke start --plugin dev.herdr-block-sleep
```

## Local development install

`plugin link` does not run build commands for local plugin development, so build first:

```sh
cd ~/dev/herdr-block-sleep
swiftc src/main.swift -O -o bin/herdr-block-sleep
herdr plugin link .
herdr plugin action invoke start --plugin dev.herdr-block-sleep
```

The plugin manifest calls the Swift binary directly; there is no shell wrapper.

Check status:

```sh
herdr plugin action invoke status --plugin dev.herdr-block-sleep
herdr plugin log list --plugin dev.herdr-block-sleep --limit 5
```

Stop the monitor:

```sh
herdr plugin action invoke stop --plugin dev.herdr-block-sleep
```

Uninstall or unlink:

```sh
herdr plugin unlink dev.herdr-block-sleep
```

## Verify the macOS assertion

When an agent is working and the lid is open:

```sh
pmset -g assertions | sed -n '/herdr-block-sleep/,+8p'
```

Expected owner:

```text
pid ... (herdr-block-sleep): PreventUserIdleSystemSleep named: "Herdr agents working (...)"
```


## Configuration

Optional environment variables:

- `HERDR_BLOCK_SLEEP_LID_CHECK_SECONDS` — local lid-state check interval while waiting for Herdr events, default `15`
- `HERDR_BLOCK_SLEEP_RECONCILE_SECONDS` — full agent-list reconciliation interval, default `300`
- `HERDR_BLOCK_SLEEP_MAX_FAILURES` — consecutive Herdr API failures before exit, default `4`

Herdr plugin state lives under `HERDR_PLUGIN_STATE_DIR`. The plugin writes:

- `daemon.pid`
- `status.json`
- `block-sleep.log`
