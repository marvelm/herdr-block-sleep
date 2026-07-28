# herdr-block-sleep

- [herdr](https://herdr.dev) plugin for macOS that prevents sleep while agents are working.

The plugin builds a Swift binary that sets up IOKit power assertions.

## Behaviour

The monitor blocks macOS from sleeping if agents are active, and only if the laptop lid is open.

## Requirements

- macOS
- Herdr 0.7.0 or newer
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

On first install, you'll need to manually invoke the plugin to start:

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

Expected owners include the non-display assertions only:

```text
pid ... (herdr-block-sleep): PreventUserIdleSystemSleep named: "Herdr agents working (...)"
pid ... (herdr-block-sleep): PreventSystemSleep named: "Herdr agents working (...)"
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
