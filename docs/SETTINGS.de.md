# Einstellungen-Referenz

**Sprache: [English](SETTINGS.md) | Deutsch**

SplashBar ist ein **Controller**, kein Server: sie enthält keine eigene
Inferenz-Engine. Sie arbeitet auf zwei unabhängigen Untersystemen, und
fast jede Einstellung gehört genau zu einem davon:

```
        SplashBar app (Menüleiste)
         │                    │
   [launchd + plist]      [HTTP API]
   "wer startet den     "wie die App mit dem
    Server, stoppt ihn,  laufenden Server
    wo er loggt"         spricht: Status, Modell, Chat"
         │                    │
    Splash-Server auf 127.0.0.1:8080
```

Es gibt 15 Einstellungen in sechs Gruppen.

## 1. App — „Startet SplashBar selbst bei der Anmeldung?"

| Einstellung | Standard | Was sie tut |
|---|---|---|
| **Bei der Anmeldung starten** | entspricht dem Zustand auf der Platte | SplashBars *eigener* LaunchAgent — `~/Library/LaunchAgents/local.splashbar.plist`, installiert von `build.sh`. **Aus:** Die App entlädt den Agenten und **löst die Plist-Datei auf** (der Bootout wird übersprungen, wenn der Prozess des Agenten die laufende App-Instanz selbst ist — das würde die App beenden). **An:** Die App legt die Datei neu an; sie enthält keinen Nutzerzustand (festes Label, fester Binary-Pfad), bei der Entfernung geht nichts verloren. Die Änderung wirkt ab dem **nächsten Login** — aus der laufenden App heraus wird der Agent nie gebootstrapt, das würde eine zweite Instanz starten. **Steuert zugleich den LLM-Server:** Der `RunAtLoad`-Key des Server-Agenten wird mit diesem Schalter synchron gehalten (von der App bei jedem Speichern, bei jedem Refresh und von `build.sh`), das Splash-Executable startet bei der Anmeldung also nur automatisch, wenn die App ebenfalls startet — und es beaufsichtigen kann. **Aus** → der Server-Agent bleibt auf der Platte (er trägt die serve-Konfiguration, die **Starten**/**Stoppen** nutzen), aber mit `RunAtLoad=false`; das Executable startet dann nur noch über das Menü |

## 2. Verbindung — „Wo ist der Server?"

| Einstellung | Standard | Was sie tut |
|---|---|---|
| **Server-URL** | `http://127.0.0.1:8080` | Ziel des Health-Checks (`GET /v1/models`), des Modell-Pickers und des Chat-Kurzbefehls. **Wichtig:** Zeigt die URL nicht auf localhost/127.0.0.1, werden die LaunchAgent-Funktionen (Start, Stopp, Modell, Kontext) mit einer Warnung deaktiviert — launchd kann nur lokale Dienste verwalten |
| **API-Timeout** | 2 s | Zeitbudget für den Health-Check (`curl -m`). Überschritten → roter Punkt „nicht erreichbar". Bewusst niedrig, damit ein *toter* Server rot statt „langsam" anzeigt |
| **Aktualisierungsintervall** | 5 s | Wie oft die App Status, Speicherbezug und geladenes Modell abfragt. Größer = ruhiger, kleiner = frischer |

## 3. Start — „Wie startet der Server?" (nur localhost)

| Einstellung | Standard | Was sie tut |
|---|---|---|
| **LaunchAgent-Label** | `local.llm.splash` | Der launchd-Dienstname — die Adresse für Start/Stopp/Status. Ein Wechsel erfordert, dass das alte plist vorher entfernt wird (sonst wird das Speichern abgelehnt) |
| **LaunchAgent-plist** | `~/Library/LaunchAgents/local.llm.splash.plist` | Die Datei, die definiert, wie `splash serve` gestartet wird — das einzige Stück, das Neustarts überlebt. SplashBar **überschreibt** diese Datei bei jedem Speichern. Ihr `RunAtLoad`-Key folgt dem Schalter **Bei der Anmeldung starten** (Gruppe 1): **an** → der Server startet bei jedem Login zusammen mit der App; **aus** → das Executable startet nicht mehr automatisch, und **Starten** im Menü ist der einzige Weg, es zu fahren |
| **Protokollpfad** | `~/Library/Logs/Splash/splash.log` | Wohin launchd die stdout/stderr-Ausgabe des Servers schreibt (`StandardOutPath`/`StandardErrorPath`). „Protokoll anzeigen" im Menü öffnet diese Datei |

Zusätzlich wechselt der **Versionsauswahl** im Menü (ein Menüeintrag, kein
Einstellungsfeld) zwischen der globalen Splash-Installation in deinem PATH
(Homebrew, …) und stabilen GitHub-Releases — die werden nach
`~/.splashbar/splash-versions/<version>` heruntergeladen und nur von
SplashBar verwendet, ohne den PATH anzufassen. Die Auswahl wird mit den
Einstellungen gespeichert, ändert aber direkt den ausführbaren Pfad des
LaunchAgenten — sie braucht nie ein „Speichern".

## 4. Modell & Kontext — „Was lädt der Server?"

| Einstellung | Standard | Was sie tut |
|---|---|---|
| **✓ Kompatibel mit Splash x.y** | — | Modelle, die Splash offiziell unterstützt (`splash serve --list-models`). Nur wählbar, nicht editierbar |
| **✕ Nicht unterstützt / ungetestet** | — | Modelle, die auf der Platte gefunden wurden (Downloads-Ordner, Hugging-Face-Cache, zusätzlicher Pfad) und nicht in der Unterstützungsliste stehen. Wählbar, mit Warnung |
| **Eigene Modell-ID** | leer = automatisch | Freies Feld für alles andere (z. B. eine Hugging-Face-ID) → wird als `--model` in das plist geschrieben. Leer lässt Splash seinen Standard wählen |
| **Kontextgröße** | Automatisch | Setzt `--max-context` (16K–256K). **Automatisch** lässt das Flag komplett weg → Splash dimensioniert seinen KV-Cache aus dem freien RAM beim Start (deshalb siehst du z. B. 180K auf einer 36-GB-Maschine). Ein fester Wert gibt planbaren, reproduzierbaren RAM-Verbrauch |
| **Modell-Cache-Ordner** | `~/.cache/huggingface/hub` | Wo Splash die Modell-Gewichte liest — der Hugging-Face-Hub-Cache. Wird als `HF_HUB_CACHE`-Umgebungsvariable in das plist geschrieben, damit alle künftigen Downloads (und vorhandenen Gewichte) dort landen. Zeige ihn auf einen sichtbaren Home-Ordner, um die Modell-Dateien zu sehen; ein leeres Feld fällt auf den Standardort zurück. Der Ordner wird automatisch angelegt |

### Wo das Modell tatsächlich liegt

Drei Schichten, und nur die erste ist die echten Daten:

```
~/.cache/huggingface/hub/models--<org>--<modell>/…        ← die Gewichte (GB)
~/Library/Application Support/Splash/models/.resolved/    ← Symlinks in den Cache
~/Library/Application Support/Splash/models/<org>/<m>     ← ein Symlink auf .resolved
```

Den Application-Support-Baum löschen ist harmlos (er wird beim nächsten
Start aus dem Cache neu aufgebaut); den Hub-Cache löschen kappt das Modell,
bis es neu heruntergeladen wurde. Die Offline-Rückroute steht unter
**Modell-Backups** weiter unten.

## 5. Zugriff — „Wer darf mit dem Server sprechen?"

| Einstellung | Standard | Was sie tut |
|---|---|---|
| **API-Schlüssel** | keiner | Wird als `--api-key` in das plist geschrieben und bei jedem Health-Check und Modell-Abfrage als `x-api-key`-Header gesendet, damit ein mit Schlüssel gestarteter Server weiterhin grün statt „nicht erreichbar" liest |
| **Erlaubter Host** | keiner | Wird als `--allowed-host` geschrieben; der Server akzeptiert nur Anfragen von diesem Host (nützlich, wenn der Port nicht an Loopback gebunden ist). Ein leerer Wert entfernt das Flag |

Beide Felder sind Klartext und werden im plist im Klartext gespeichert —
in Ordnung für einen nur-Loopback-Server, aber zeige einen mit Schlüssel
versehenen Server nicht mit einem wichtigen Schlüssel ins Netzwerk.

## 6. Überwachung — „Was bedeuten die Punkt-Farben?"

| Einstellung | Standard | Was sie tut |
|---|---|---|
| **Idle-Grenze** | 3,0 GB | Footprint-Schwelle: Der Server läuft, aber sein RAM-Spitzenwert bleibt *unter* dieser Linie und keine Anfrage ist aktiv → „idle" (grün, gedimmt). Darüber → „aktiv" (grün). Auf einer Maschine, deren Modell-Ruhelage über dem Standard liegt, den Wert entsprechend anheben |

## So funktioniert „Speichern"

```
Speichern → alles validieren → ① App-Einstellungen in UserDefaults
                                    (defaults read local.splashbar,
                                     inkl. Bei-der-Anmeldung-Starten)
                                      → ② LaunchAgent-plist neu schreiben
                                         (--model, --max-context, --api-key,
                                          --allowed-host, Protokollpfad,
                                          Label,
                                          EnvironmentVariables:
                                          HF_HUB_CACHE)
                                      → ③ „Anwenden und neu starten?"
                                          → „speichern, später anwenden"
                                            verzögert den Neustart;
                                          „anwenden" = stop + bootout + bootstrap
                                      → ④ (wieder-)anlegen oder löschen des
                                          eigenen local.splashbar.plist,
                                          wenn sich der Schalter geändert
                                          hat, und den RunAtLoad des
                                          Splash-Agenten daran ausrichten
```

- **Sofort aktiv** (nur App, kein Server-Neustart nötig): Server-URL,
  Timeout, Aktualisierungsintervall, Idle-Grenze
- **Beim nächsten Start aktiv** (wegen ③): Modell, Kontextgröße,
  API-Schlüssel, erlaubter Host, Modell-Cache-Ordner, plist-Pfade, Label

## Wo Einstellungen gespeichert werden

- **App-Präferenzen** (URL, Timeout, Aktualisierung, Idle, Modell, Kontext,
  API-Schlüssel, erlaubter Host, Modell-Cache-Ordner, gewählte Version,
  Pfade, Bei-der-Anmeldung-Starten): macOS-UserDefaults, Domain
  `local.splashbar` — einsehbar mit `defaults read local.splashbar`
- **Eigener LaunchAgent der App** (Bei der Anmeldung starten):
  `~/Library/LaunchAgents/local.splashbar.plist` — von der App und von
  `build.sh` (de)installiert; `build.sh` überspringt die Neu-Installation,
  wenn das Setting aus ist, und patcht den `RunAtLoad`-Key des
  Splash-Agenten entsprechend
- **Server-Startkonfiguration**: das LaunchAgent-plist aus Gruppe 3 — die
  Quelle dafür, wie `splash serve` gestartet wird. Das plist von Hand zu
  editieren funktioniert für die meisten Keys, aber das nächste „Speichern"
  in der App überschreibt es aus den gespeicherten Einstellungen — und
  `RunAtLoad` wird bei jedem Speichern *und* bei jedem Refresh mit dem
  Bei-der-Anmeldung-Starten-Schalter neu synchronisiert, ein Hand-Edit an
  dem Key wird also zurückgerollt
- **Modell-Backups**: `~/SplashBar-Backups/models-<zeitstempel>.tar` —
  angelegt durch den Menüeintrag „Modell sichern…" (siehe unten)

## Modell-Backups (Notfall-Fallback)

Die Menüeinträge **Modell sichern…** und **Modell wiederherstellen…**
schützen gegen den einen Fall, den nichts anderes abdeckt: Der
Modell-Cache wird gelöscht oder beschädigt, und der einzige Weg zurück
wäre ein mehr-GB-Neu-Download.

- **Modell sichern…** tar-t den gesamten Modell-Cache (den *Modell-Cache-Ordner*
  aus Gruppe 4) nach `~/SplashBar-Backups/models-<zeitstempel>.tar`, mit
  Fortschrittsbalken und Abbruch. Der Cache selbst bleibt unangetastet;
  das Backup ist eine zweite Kopie.
- **Modell wiederherstellen…** listet die vorhandenen Archive, lässt ein
  auswählen und stellt es *transaktional* wieder her: Der aktuelle Cache wird
  erst beiseitegeschoben, das Archiv entpackt, und wenn das fehlschlägt,
  wird der alte Cache zurückgeschoben. Eine fehlgeschlagene oder abgebrochene
  Wiederherstellung hinterlässt nie eine halbe Wiederherstellung.

Ein Time-Machine- oder sonstiges Platten-Backup von `~/` deckt denselben
Fall automatisch ab — diese Einträge sind die schnelle, in-der-App-Version
davon.

## Hinweise

- Bei jedem Start richtet die App den Zustand auf der Platte mit der
  gespeicherten Bei-der-Anmeldung-Starten-Präferenz ab: Ist der Schalter
  aus, wird der eigene Agent der App entfernt, falls er wieder existiert
  (z. B. weil `build.sh` mit einer älteren Version gelaufen ist), und der
  `RunAtLoad`-Key des Splash-Agenten wird auf false gesetzt — mit dem
  Schalter aus startet beim Login also **nichts** automatisch. `build.sh`
  wendet dasselbe Abgleichen zum Build-Zeitpunkt an und deckt so die Lücke
  bis zum nächsten App-Start ab.
- Der Chat-Kurzbefehl, der Modell-Picker und das Kontext-/Modell-Menü
  lesen vom **laufenden** Server aus `/v1/models` — nicht aus den
  Einstellungen — und spiegeln also immer wider, was der Server tatsächlich
  geladen hat.
- Eine Server-URL im Netz funktioniert für Überwachung und Chat, aber der
  Server-Lebenszyklus (Start/Stopp/Version/Modell/Kontext) ist immer
  nur-lokal.
- Von SplashBar verwaltete Versionen liegen in
  `~/.splashbar/splash-versions/`; ein Ordner zu löschen entfernt diese
  Version aus der Auswahl. Ein Release-Archiv wird heruntergeladen,
  SHA-256-verifiziert und in einen Staging-Ordner entpackt, bevor es an
  seinen Platz gezogen wird — ein unvollendeter Download kann also eine
  vorhandene Version nie beschädigen.
