# Settings Reference

**Language: English | [Deutsch](SETTINGS.de.md)**

SplashBar is a **controller**, not a server: it contains no inference engine of
its own. It works on top of two independent subsystems, and almost every
setting belongs to exactly one of them:

```
        SplashBar app (menu bar)
         │                    │
   [launchd + plist]      [HTTP API]
   "who starts the       "how the app talks
    server, stops it,     to the running
    where it logs"        server: status, model, chat"
         │                    │
    Splash server on 127.0.0.1:8080
```

There are 15 settings in 6 groups.

## 1. App — "does SplashBar itself start at login?"

| Setting | Default | What it does |
|---|---|---|
| **Launch at login** | matches what is on disk | SplashBar's *own* LaunchAgent — `~/Library/LaunchAgents/local.splashbar.plist`, installed by `build.sh`. **Off:** the app unloads the agent and **removes the plist file** (booting out is skipped when the agent's process is the running app instance, which would terminate the app). **On:** the app recreates the file; it holds no user state (fixed label and executable path), so removing it loses nothing. The change takes effect at the **next login** — the agent is never bootstrapped from the running app, because that would start a second instance. **It also controls the LLM server:** the server agent's `RunAtLoad` key is kept in sync with this toggle (by the app on every save, on every refresh, and by `build.sh`), so the splash executable only auto-starts at login when the app starts too — and can supervise it. **Off** → the server agent stays on disk (it holds the serve configuration used by **Start**/**Stop**) but with `RunAtLoad=false`; the executable then starts only via the menu |

## 2. Connection — "where is the server?"

| Setting | Default | What it does |
|---|---|---|
| **Server URL** | `http://127.0.0.1:8080` | Target of the health check (`GET /v1/models`), the model picker, and the chat shortcut. **Important:** if the URL does not point at localhost/127.0.0.1, the LaunchAgent features (start, stop, model, context) are disabled with a warning — launchd can only manage local services |
| **API timeout** | 2 s | Time budget for the health probe (`curl -m`). Exceeded → red dot "unreachable". Deliberately low, so a *dead* server shows red instead of "slow" |
| **Refresh interval** | 5 s | How often the app polls for status, footprint, and the loaded model. Larger = quieter, smaller = fresher |

## 3. Launch — "how does the server start?" (localhost only)

| Setting | Default | What it does |
|---|---|---|
| **LaunchAgent label** | `local.llm.splash` | The launchd service name — the address used for start/stop/status. Changing it requires the old plist to be removed first (otherwise the save is rejected) |
| **LaunchAgent plist** | `~/Library/LaunchAgents/local.llm.splash.plist` | The file that defines how `splash serve` is started — the only piece that survives reboots. SplashBar **rewrites** this file on every save. Its `RunAtLoad` key follows the **Launch at login** toggle (group 1): **on** → the server starts at every login together with the app; **off** → the executable no longer auto-starts, and the menu's **Start** is the only way to launch it |
| **Log path** | `~/Library/Logs/Splash/splash.log` | Where launchd writes the server's stdout/stderr (`StandardOutPath`/`StandardErrorPath`). "Open log" in the menu opens this file |

In addition, the **version selector** in the menu (a menu entry, not a
settings field) switches between the global Splash install on the user's PATH
(Homebrew, …) and stable GitHub releases, which are downloaded to
`~/.splashbar/splash-versions/<version>` and used by SplashBar only, without
touching the PATH. The selection is stored with the settings but changes the
LaunchAgent's executable path directly — it never needs a "Save".

## 4. Model & context — "what does the server load?"

| Setting | Default | What it does |
|---|---|---|
| **✓ Compatible with Splash x.y** | — | Models Splash officially supports (`splash serve --list-models`). Selection only, not editable |
| **✕ Unsupported / untested** | — | Models found on disk (Downloads folder, Hugging Face cache, extra path) that are not in the support list. Selectable, with a warning |
| **Custom model ID** | empty = auto | Free field for anything else (e.g. a Hugging Face ID) → written as `--model` into the plist. Empty lets Splash pick its default |
| **Context size** | Automatic | Sets `--max-context` (16K–256K). **Automatic** omits the flag entirely → Splash sizes its KV cache from the free RAM at startup (this is why you can see e.g. 180K on a 36 GB machine). A pinned value gives predictable, reproducible RAM usage |
| **Model cache directory** | `~/.cache/huggingface/hub` | Where Splash reads the model weights from — the Hugging Face hub cache. Written as the `HF_HUB_CACHE` environment variable into the plist, so all future downloads (and existing weights) resolve there. Point it at a visible home folder to see the model files; an empty field falls back to the standard location. The directory is created automatically |

### Where the model actually lives

Three layers, and only the first one is the real data:

```
~/.cache/huggingface/hub/models--<org>--<model>/…      ← the weights (GBs)
~/Library/Application Support/Splash/models/.resolved/  ← symlinks into the cache
~/Library/Application Support/Splash/models/<org>/<m>  ← a symlink to .resolved
```

Deleting the Application Support tree is harmless (it is rebuilt from the
cache on the next start); deleting the hub cache breaks the model until it is
downloaded again. See **Backups** below for the offline way back.

## 5. Access — "who may talk to the server?"

| Setting | Default | What it does |
|---|---|---|
| **API key** | none | Written as `--api-key` into the plist and sent as an `x-api-key` header on every health check and model probe, so a server started with a key still reads as green instead of "unreachable" |
| **Allowed host** | none | Written as `--allowed-host`; the server only accepts requests from this host (useful when the port is not bound to loopback). An empty value removes the flag |

Both fields are plain text and are stored in the plist in clear text — fine
for a loopback-only server, but do not point a keyed server at the network
with a key you care about.

## 6. Monitoring — "what does the dot color mean?"

| Setting | Default | What it does |
|---|---|---|
| **Idle threshold** | 3.0 GB | Footprint cutoff: the server is running but its peak RAM stays *below* this line and no request is active → "idle" (green, dim). Above it → "busy" (green). On a machine whose model footprint at rest is higher than the default, raise the value to match |

## How "Save" works

```
Save → validate everything → ① app settings into UserDefaults
                                    (defaults read local.splashbar,
                                     incl. launch-at-login)
                           → ② rewrite the LaunchAgent plist
                              (--model, --max-context, --api-key,
                               --allowed-host, log path, label,
                               EnvironmentVariables: HF_HUB_CACHE)
                           → ③ "Apply and restart?"
                               → "save, apply later" defers the restart;
                               "apply" = stop + bootout + bootstrap
                           → ④ (re)create or remove the app's own
                               local.splashbar.plist, if the toggle changed,
                               and sync the splash agent's RunAtLoad to it
```

- **Active immediately** (app-only, no server restart needed): server URL,
  timeout, refresh interval, idle threshold
- **Active on next start** (because of ③): model, context size, API key,
  allowed host, model cache directory, plist paths, label

## Where settings are stored

- **App preferences** (URL, timeout, refresh, idle, model, context, API key,
  allowed host, model cache directory, selected version, paths, launch-at-login): macOS UserDefaults,
  domain `local.splashbar` — inspect with `defaults read local.splashbar`
- **App's own LaunchAgent** (launch-at-login): `~/Library/LaunchAgents/local.splashbar.plist` —
  created/removed by the app and by `build.sh` (which skips the (re)install when the
  setting is off, and patches the splash agent's `RunAtLoad` to match it)
- **Server launch configuration**: the LaunchAgent plist from group 3 — the
  source of truth for how `splash serve` is started. Editing the plist by hand
  works for most keys, but the next "Save" in the app overwrites it from the
  stored settings — and `RunAtLoad` is re-synced with the launch-at-login
  toggle on every save *and* on every refresh, so a hand edit there reverts.
- **Model backups**: `~/SplashBar-Backups/models-<timestamp>.tar` — created
  by the "Back up model…" menu entry (see below)

## Model backups (emergency fallback)

The menu entries **Back up model…** and **Restore model…** guard against the
one scenario nothing else covers: the model cache getting deleted or
corrupted, so the only way back would be a multi-GB re-download.

- **Back up model…** tars the whole model cache (group 4's *Model cache
  directory*) into `~/SplashBar-Backups/models-<timestamp>.tar` with a
  progress bar and cancel. The cache itself stays untouched; the backup is a
  second copy.
- **Restore model…** lists the existing archives, lets you pick one, and
  restores it *transactionally*: the current cache is moved aside first, the
  archive is extracted, and if that fails the old cache is moved back. A
  failed or cancelled restore never leaves a half-restore behind.

A Time Machine or other disk backup of `~/` covers the same scenario
automatically — these entries are the fast, in-app version of that.

## Notes

- On every start the app reconciles the on-disk state with the stored
  launch-at-login preference: if launch-at-login is off, the app's own agent
  is removed when it exists again (for example because `build.sh` was run
  with an older version), and the splash agent's `RunAtLoad` is set to false
  — so with the toggle off, **nothing** auto-starts at login. `build.sh`
  applies the same reconciliation at build time, covering the gap until the
  app next runs.
- The chat shortcut, the model picker, and the context/model menu all read
  from the **running** server's `/v1/models` — not from the settings — so they
  always reflect what the server actually has loaded.
- A remote server URL works for monitoring and chat, but the server lifecycle
  (start/stop/version/model/context) is always local-only.
- SplashBar-managed versions live in `~/.splashbar/splash-versions/`;
  deleting a folder removes that version from the selector. A release archive
  is downloaded, SHA-256-verified, and extracted to a staging directory before
  it is moved into place, so a half-finished download never corrupts an
  existing version.
