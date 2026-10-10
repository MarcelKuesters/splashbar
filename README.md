# SplashBar

A tiny macOS menu bar app to control a local [Splash](https://github.com/incoai/splash)
inference server: start/stop/restart the `launchctl` service, watch the model's
GPU memory footprint, and jump straight to the built-in chat page.

![menu](docs/menu.png)

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

The app talks to a fixed set of paths defined at the top of `main.swift`:

| Constant      | Meaning                                   | Default                          |
|---------------|-------------------------------------------|----------------------------------|
| `label`       | Splash's launchd agent label              | `local.llm.splash`               |
| `chatURL`     | Splash web chat                           | `http://127.0.0.1:8080`          |
| `logPath`     | Splash server log                         | `~/Library/Logs/Splash/splash.log` |
| `plistPath`   | Splash agent plist                        | `~/Library/LaunchAgents/local.llm.splash.plist` |

If your Splash setup uses different values, edit the constants at the top of
`main.swift` and rebuild. (A `--config` file is on the roadmap.)

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
