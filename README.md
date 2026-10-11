# SplashBar

A tiny macOS menu bar app to control a local [Splash](https://github.com/incoai/splash)
inference server: start/stop/restart the `launchctl` service, watch the model's
GPU memory footprint, and jump straight to the built-in chat page.

The status dot in the menu bar does the talking:

| Dot | State | Meaning |
|-----|-------|---------|
| 🟢 green | serving | model loaded, answering requests |
| 🔵 blue | idle | loaded but unloaded to save memory (re-loads in ~5 s) |
| 🟠 orange | loading | server up, pulling the model in |
| ⚪ gray | stopped | agent stopped, memory freed |

![The SplashBar menu](docs/menu.png)

## What it does

- Shows the Splash server state in the menu bar (● green = serving, blue = idle,
  orange = loading model, gray = stopped)
- Reads the real memory footprint via `footprint(1)` — the model lives in
  GPU/phys_footprint, not in RSS
- Start / Stop (frees RAM + VRAM) / Restart without opening Terminal
- Opens the chat UI at `http://127.0.0.1:8080` and the server log

No dependencies, no installer, no daemon of its own — one Swift file, built
with the Swift toolchain that ships with macOS.

## Requirements

- macOS 14+
- [Splash](https://github.com/incoai/splash) installed and running as the
  launchd agent `local.llm.splash` with the chat page on port 8080
- `footprint` tool from Apple's `dev-tools` package (for the memory readout;
  without it the app still works, just shows no number)

## Build & run

```sh
bash build.sh            # builds /Applications/SplashBar.app + launch agent, starts it
```

The build script also (re)registers the `local.splashbar` LaunchAgent so
SplashBar auto-starts at login.

### Configuration

Open **Einstellungen …** from the SplashBar menu to configure your Splash
installation. Settings are saved for the current macOS user and take effect
without rebuilding the app.

| Setting | Default |
|---------|---------|
| Server URL (chat and API health check) | `http://127.0.0.1:8080` |
| Splash LaunchAgent label | `local.llm.splash` |
| Splash LaunchAgent plist | `~/Library/LaunchAgents/local.llm.splash.plist` |
| Splash log | `~/Library/Logs/Splash/splash.log` |
| Status refresh interval | 5 seconds |
| API request timeout | 2 seconds |
| Idle memory threshold | 3 GB |

The server URL is shared by the chat shortcut and the `/v1/models` health
check. Paths may start with `~` to refer to your home directory.

## Uninstall

```sh
launchctl bootout gui/$(id -u)/local.splashbar
rm ~/Library/LaunchAgents/local.splashbar.plist /Applications/SplashBar.app
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and feature requests are
welcome — open an issue, especially if your Splash install lives at a
different port or label.

## License

MIT — see [LICENSE](LICENSE).
