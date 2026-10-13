# Settings Reference

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

There are 12 settings in four groups.

## 1. Connection — "where is the server?"

| Setting | Default | What it does |
|---|---|---|
| **Server URL** | `http://127.0.0.1:8080` | Target of the health check (`GET /v1/models`), the model picker, and the chat shortcut. **Important:** if the URL does not point at localhost/127.0.0.1, the LaunchAgent features (start, stop, model, context) are disabled with a warning — launchd can only manage local services |
| **API timeout** | 2 s | Time budget for the health probe (`curl -m`). Exceeded → red dot "unreachable". Deliberately low, so a *dead* server shows red instead of "slow" |
| **Refresh interval** | 5 s | How often the app polls for status, footprint, and the loaded model. Larger = quieter, smaller = fresher |

## 2. Launch — "how does the server start?" (localhost only)

| Setting | Default | What it does |
|---|---|---|
| **LaunchAgent label** | `local.llm.splash` | The launchd service name — the address used for start/stop/status. Changing it requires the old plist to be removed first (otherwise the save is rejected) |
| **LaunchAgent plist** | `~/Library/LaunchAgents/local.llm.splash.plist` | The file that makes the LLM start at every login — the only piece that survives reboots. SplashBar **rewrites** this file on every save |
| **Log path** | `~/Library/Logs/Splash/splash.log` | Where launchd writes the server's stdout/stderr (`StandardOutPath`/`StandardErrorPath`). "Open log" in the menu opens this file |

## 3. Model & context — "what does the server load?"

| Setting | Default | What it does |
|---|---|---|
| **✓ Compatible with Splash x.y** | — | Models Splash officially supports (`splash serve --list-models`). Selection only, not editable |
| **✕ Unsupported / untested** | — | Models found on disk (Downloads folder, Hugging Face cache, extra path) that are not in the support list. Selectable, with a warning |
| **Custom model ID** | empty = auto | Free field for anything else (e.g. a Hugging Face ID) → written as `--model` into the plist. Empty lets Splash pick its default |
| **Context size** | Automatic | Sets `--max-context` (16K–256K). **Automatic** omits the flag entirely → Splash sizes its KV cache from the free RAM at startup (this is why you can see e.g. 180K on a 36 GB machine). A pinned value gives predictable, reproducible RAM usage |

## 4. Monitoring — "what does the dot color mean?"

| Setting | Default | What it does |
|---|---|---|
| **Idle threshold** | 3.0 GB | Footprint cutoff: the server is running but its peak RAM stays *below* this line and no request is active → "idle" (green, dim). Above it → "busy" (green). On a machine whose model footprint at rest is higher than the default, raise the value to match |

## How "Save" works

```
Save → validate everything → ① app settings into UserDefaults
                                    (defaults read local.splashbar)
                           → ② rewrite the LaunchAgent plist
                              (--model, --max-context, log path, label)
                           → ③ "Apply and restart?"
                              → bootout + bootstrap = server restarts
```

- **Active immediately** (app-only, no server restart needed): server URL,
  timeout, refresh interval, idle threshold
- **Active on next start** (because of ③): model, context size, plist paths,
  label

## Where settings are stored

- **App preferences** (URL, timeout, refresh, idle, model, context, paths):
  macOS UserDefaults, domain `local.splashbar` — inspect with
  `defaults read local.splashbar`
- **Server launch configuration**: the LaunchAgent plist from group 2 — the
  source of truth for how `splash serve` is started. Editing the plist by hand
  works, but the next "Save" in the app overwrites it from the stored settings.

## Notes

- The chat shortcut, the model picker, and the context/model menu all read
  from the **running** server's `/v1/models` — not from the settings — so they
  always reflect what the server actually has loaded.
- A remote server URL works for monitoring and chat, but the server lifecycle
  (start/stop/version/model/context) is always local-only.
