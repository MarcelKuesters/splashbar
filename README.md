# SplashBar

A tiny macOS menu bar app to control a local [Splash](https://github.com/incoai/splash)
inference server: start/stop/restart the `launchctl` service, watch the model's
GPU memory footprint, see the model that is actually loaded, switch between
published Splash releases, and jump straight to the built-in chat page.

The status dot in the menu bar does the talking:

| Dot | State | Meaning |
|-----|-------|---------|
| 🟢 green | serving | model loaded, answering requests |
| 🔵 blue | idle | loaded but unloaded to save memory (re-loads in ~5 s) |
| 🟠 orange | loading | server up, pulling the model in |
| ⚪ gray | stopped | agent stopped, memory freed |

The menu below is shown in German because that is SplashBar's development
language; all menus follow the macOS system language and are localized in
seven languages (de, en, fr, es, ja, zh, ru).

![The SplashBar menu](docs/menu.png)

## What it does

- Shows the Splash server state in the menu bar (● green = serving, blue = idle,
  orange = loading model, gray = stopped)
- Reads the real memory footprint via `footprint(1)` — the model lives in
  GPU/phys_footprint, not in RSS
- Start / Stop (frees RAM + VRAM) / Restart without opening Terminal
- Opens the chat UI at `http://127.0.0.1:8080` and the server log
- Selects the model ID passed to `splash serve --model`
- Chooses the context size passed to `splash serve --max-context` (auto = the model's native window)
- Shows the installed Splash version and can install or switch between published stable GitHub releases
- Shows the model that is currently loaded (live, from the server's `/v1/models`)

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
without rebuilding the app. [The full reference for every setting](docs/SETTINGS.md)
covers where each one applies and how "Save" propagates to the LaunchAgent.

| Setting | Default |
|---------|---------|
| Server URL (chat and API health check) | `http://127.0.0.1:8080` |
| Splash LaunchAgent label | `local.llm.splash` |
| Splash LaunchAgent plist | `~/Library/LaunchAgents/local.llm.splash.plist` |
| Splash log | `~/Library/Logs/Splash/splash.log` |
| Status refresh interval | 5 seconds |
| API request timeout | 2 seconds |
| Idle memory threshold | 3 GB |
| Splash model ID | Read from the LaunchAgent; empty until configured |
| Context size (--max-context) | Auto — the argument is left out |
| Additional model search folder | None |

The server URL is shared by the chat shortcut and the `/v1/models` health
check. Paths may start with `~` to refer to your home directory. Choose a
suggested model or enter a custom repository ID such as
`mlx-community/Qwen3.8-27B-4bit` in the editable model field.
Saving a new model or a different context size updates the configured Splash
LaunchAgent. If the server is already loaded, SplashBar asks before restarting
it; if it is stopped, the LaunchAgent is prepared and the next **Starten**
action starts it.

The context size caps the window available per conversation; `Auto` lets
Splash keep the model's native window when memory allows and is not written
to the LaunchAgent at all.

The model list scans the Hugging Face cache used by Splash (`HF_HUB_CACHE`,
`HF_HOME/hub`, or `~/.cache/huggingface/hub`) and LM Studio's
`~/.lmstudio/models` folder. An optional additional folder can be entered in
settings or selected with **Durchsuchen …** in the folder picker; the model
lists are rescanned immediately after choosing it. It is scanned alongside
those standard locations. Models found in these folders are listed by
repository ID. The selector has separate lists
headed with the installed Splash version: compatible models are above, while
incompatible and unverified models are below. Legacy `*-Splash` packages are
marked compatible through Splash 1.3.0 and incompatible with Splash 1.3.1 or
newer. Other discovered repositories are marked unverified unless they are
one of the built-in model suggestions. A local folder being found does not by
itself guarantee that its model format is supported by the installed Splash
version. A separate editable field accepts a custom repository ID.

**Splash-Version auswählen …** loads the stable releases from the official
GitHub Releases API. It offers releases that include the macOS ARM64 runtime
archive and its SHA-256 checksum. SplashBar writes a version-specific formula
to a local, non-Git Homebrew tap; Homebrew verifies the downloaded archive
against the release checksum and keeps versions side by side for later
switching. SplashBar asks before the switch and restarts a loaded server
afterward; a stopped server remains stopped. Check model compatibility before
switching; Splash 1.3.1, for example, no longer loads the older `*-Splash`
packages. After confirming a version change, SplashBar shows a progress window.
If the operation fails, the window points to a detailed log with command output
and the application stack trace in `~/Library/Logs/SplashBar/`.

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
