# SplashBar

**Sprache: [English](README.md) | Deutsch**

Eine kleine macOS-Menüleisten-App, um einen lokalen
[Splash](https://github.com/incoai/splash)-Inferenzserver zu steuern:
den `launchctl`-Dienst starten/stoppen/neu starten, den
Arbeitsspeicher-Beleg des Modells im Blick behalten, das tatsächlich
geladene Modell sehen, zwischen veröffentlichten Splash-Releases wechseln
und direkt zur eingebauten Chat-Seite springen.

Der Status-Punkt in der Menüleiste spricht für sich:

| Punkt | Zustand | Bedeutung |
|-------|---------|-----------|
| 🟢 grün | serving | Modell geladen, beantwortet Anfragen |
| 🔵 blau | idle | geladen, aber zum Sparen von Arbeitsspeicher entladen (lädt in ~5 s wieder) |
| 🟠 orange | loading | Server läuft, lädt das Modell |
| ⚪ grau | gestoppt | Dienst gestoppt, Speicher freigegeben |

Das Menü unten ist auf Deutsch gezeigt, weil Deutsch die
Entwicklungssprache von SplashBar ist; alle Menüs folgen der
Systemsprache und sind in sieben Sprachen lokalisiert (de, en, fr, es, ja, zh, ru).

![Das SplashBar-Menü](docs/menu.png)

## Was sie leistet

- Zeigt den Zustand des Splash-Servers in der Menüleiste
  (● grün = serving, blau = idle, orange = Modell wird geladen, grau = gestoppt)
- Liest den echten Speicherbezug über `footprint(1)` — das Modell liegt in
  GPU/phys_footprint, nicht in der RSS
- Starten / Stoppen (freit RAM + VRAM) / Neu starten, ohne das Terminal zu öffnen
- Öffnet die Chat-Oberfläche unter `http://127.0.0.1:8080` sowie das Server-Protokoll
- Wählt die Modell-ID für `splash serve --model`
- Wählt die Kontextgröße für `splash serve --max-context` (Auto = das native Fenster des Modells)
- Übergibt optional API-Schlüssel und erlaubten Host an den Server
- Zeigt die verwendete Splash-Version und kann zwischen dem global
  installierten Splash und veröffentlichten stabilen GitHub-Releases
  wechseln; Release-Versionen werden nach `~/.splashbar/splash-versions`
  heruntergeladen und nur von SplashBar verwendet, ohne deinen PATH anzufassen
- Zeigt das aktuell geladene Modell (live, aus dem `/v1/models` des Servers)
- Zeigt die SplashBar-Version oben im Menü
- Sichert den Modell-Cache nach `~/SplashBar-Backups` und stellt ihn aus
  einem Backup wieder her — der aktuelle Cache wird dabei beiseitegeschoben
  und bei Fehlern zurückgeschoben, eine Wiederherstellung kann also nie ein
  funktionierendes Modell zerstören
- Legt in den Einstellungen fest, wo der Modell-Cache liegt (der
  Hugging-Face-Ordner, den Splash liest, übergeben als `HF_HUB_CACHE`)

Keine Abhängigkeiten, kein Installer, kein eigener Daemon — eine Swift-Datei,
gebaut mit dem Swift-Toolkit, das macOS mitliefert.

## Voraussetzungen

- macOS 26.4+ (entspricht der Splash-Engine)
- [Splash](https://github.com/incoai/splash) installiert und als launchd-Dienst
  `local.llm.splash` laufend, Chat-Seite auf Port 8080 — oder wähle eines der
  stabilen GitHub-Releases im Versionsmenü; SplashBar verwaltet dann eine
  eigene Kopie in `~/.splashbar/splash-versions`
- Das `footprint`-Werkzeug aus Apples `dev-tools`-Paket (für die
  Speicheranzeige; ohne es funktioniert die App, zeigt nur keine Zahl)

## Bauen & starten

```sh
bash build.sh            # baut /Applications/SplashBar.app + LaunchAgent und startet sie
```

Das Build-Skript registriert zusätzlich den `local.splashbar`-LaunchAgent,
damit SplashBar beim Login automatisch startet.

### Konfiguration

Öffne **Einstellungen …** im SplashBar-Menü, um deine Splash-Installation
einzurichten. Einstellungen werden für den aktuellen macOS-Benutzer
gespeichert und gelten, ohne die App neu zu bauen. [Die vollständige
Referenz aller Einstellungen](docs/SETTINGS.de.md) erklärt, wo jeweils was
angewendet wird und wie „Speichern" auf den LaunchAgent durchwirkt.

| Einstellung | Standard |
|-------------|----------|
| Server-URL (Chat und API-Health-Check) | `http://127.0.0.1:8080` |
| Splash-LaunchAgent-Label | `local.llm.splash` |
| Splash-LaunchAgent-Plist | `~/Library/LaunchAgents/local.llm.splash.plist` |
| Splash-Protokoll | `~/Library/Logs/Splash/splash.log` |
| Status-Aktualisierungsintervall | 5 Sekunden |
| API-Request-Timeout | 2 Sekunden |
| Idle-Speicher-Grenze | 3 GB |
| Splash-Modell-ID | Aus dem LaunchAgent gelesen; leer, bis konfiguriert |
| Kontextgröße (--max-context) | Auto — das Argument wird weggelassen |
| API-Schlüssel (--api-key) | Keiner — das Argument wird weggelassen |
| Erlaubter Host (--allowed-host) | Keiner — das Argument wird weggelassen |
| Zusätzlicher Modell-Suchordner | Keiner |
| Modell-Cache-Ordner | `~/.cache/huggingface/hub` (Hugging-Face-Standard) |

Die Server-URL teilen sich der Chat-Kurzbefehl und der `/v1/models`-Health-Check.
Pfade dürfen mit `~` beginnen, um das Home-Verzeichnis zu meinen. Wähle ein
vorgeschlagenes Modell oder gib eine eigene Repository-ID wie
`mlx-community/Qwen3.8-27B-4bit` im editierbaren Modellfeld ein.
Speicherst du ein neues Modell oder eine andere Kontextgröße, wird der
konfigurierte Splash-LaunchAgent aktualisiert. Läuft der Server bereits,
fragt SplashBar: neu starten, um die Änderungen sofort anzuwenden, oder die
Änderungen speichern und beim nächsten Server-Start anwenden, ohne die
laufende Instanz zu unterbrechen. Ist der Server gestoppt, wird der
LaunchAgent vorbereitet und die nächste **Starten**-Aktion startet ihn.

Die Kontextgröße begrenzt das Fenster pro Konversation; `Auto` lässt Splash
das native Fenster des Modells beibehalten, soweit der Speicher reicht, und
wird gar nicht in den LaunchAgent geschrieben.

API-Schlüssel und erlaubter Host sind optional. Sind sie gesetzt, werden sie
als `--api-key` und `--allowed-host` in den Splash-LaunchAgent geschrieben;
leer bleiben die Argumente vollständig weggelassen.

Die Modell-Liste durchsucht den von Splash genutzten Hugging-Face-Cache
(`HF_HUB_CACHE`, `HF_HOME/hub` oder `~/.cache/huggingface/hub`) sowie
LM-Studios Modell-Ordner `~/.lmstudio/models`. Einen zusätzlichen Ordner kannst du
in den Einstellungen eingeben oder im Ordner-Picker mit **Durchsuchen …**
wählen; die Modell-Listen werden danach sofort neu gescannt. Der Ordner wird
neben den Standardorten durchsucht. Gefundene Modelle werden nach
Repository-ID aufgelistet. Die Auswahl hat separate Listen mit Überschrift
der installierten Splash-Version: kompatible Modelle stehen oben,
inkompatible und ungeprüfte Modelle unten. Ältere `*-Splash`-Pakete gelten
bis Splash 1.3.0 als kompatibel und ab Splash 1.3.1 als inkompatibel.
Weitere gefundene Repositories gelten als ungeprüft, außer sie sind eine der
eingebauten Modell-Vorschläge. Ein gefundener lokaler Ordner garantiert
nicht von allein, dass das Splash der installierten Version das Modellformat
unterstützt. Ein separates editierbares Feld akzeptiert eine eigene
Repository-ID.

Die Einstellung **Modell-Cache-Ordner** steuert, wo die Modell-Dateien
tatsächlich liegen: Sie wird als `HF_HUB_CACHE` in den Splash-LaunchAgent
geschrieben, sodass Splash seine Modelle dort herunterlädt und liest, statt
im Hugging-Face-Standardort. Ein leeres Feld nutzt den Standard. Das
Umziehen des Ordners ist ein Einmal-Schritt — bestehende Modell-Dateien
müssen vorher dorthin kopiert oder verschoben werden (oder aus einem Backup
wiederhergestellt), bevor das nächste Modell geladen wird.

**Splash-Version auswählen …** lädt die stabilen Releases aus der
offiziellen GitHub-Releases-API. Der erste Eintrag ist die auf deinem System
installierte Splash (zum Beispiel über Homebrew), abgeglichen gegen die
`splash`-Ausführbare in deinem PATH; die übrigen Einträge sind stabile
Releases, die das macOS-ARM64-Runtime-Archiv und seine SHA-256-Prüfsumme
enthalten. Kann die Releaseliste nicht geladen werden (kein Netzwerk, oder
GitHub ist down), listet SplashBar stattdessen die bereits in
`~/.splashbar/splash-versions` installierten Versionen; lokal installierte
Versionen sind mit `(installiert)` markiert. Wählst du eine Release-Version,
wird das Archiv (mit Fortschrittsbalken) heruntergeladen und nach
`~/.splashbar/splash-versions/<version>` entpackt — nvm-artig, jede Version
liegt nebeneinander für spätere Wechsel bereit. SplashBar nutzt diese lokalen
Kopien nur intern; nichts anderes auf deinem System, auch nicht dein PATH,
wird verändert. SplashBar fragt vor dem Wechsel und startet einen geladenen
Server danach neu; ein gestoppter Server bleibt gestoppt. Prüfe vor dem
Wechsel die Modell-Kompatibilität; Splash 1.3.1 lädt zum Beispiel die
älteren `*-Splash`-Pakete nicht mehr. Nach einer bestätigten
Versionsänderung zeigt SplashBar ein Fortschrittsfenster. Während des
Downloads bietet das Fenster einen **Abbrechen**-Button an; bestätigst du den
Abbruch, wird der Download abgebrochen, das angelegte
`~/.splashbar/splash-versions/<version>`-Verzeichnis gelöscht und die bisher
aktive Splash-Version bleibt ausgewählt. Schlägt der Vorgang fehl, verweist
das Fenster auf ein detailreiches Protokoll mit Kommandoausgabe und
Stacktrace der App in `~/Library/Logs/SplashBar/`.

### Das Modell sichern

Das Menü bietet **Modell sichern …** und **Modell wiederherstellen …**.
Eine Sicherung archiviert den Modell-Cache (standardmäßig
`~/.cache/huggingface/hub`) als `~/SplashBar-Backups/models-<zeitstempel>.tar`
in einem Fortschrittsfenster — der laufende Server und der Cache selbst
bleiben unangetastet, und die Sicherung ist abbrechbar (das halbe Archiv
wird dann gelöscht). Eine Wiederherstellung läuft transaktional ab: der
aktuelle Cache wird beiseitegeschoben, das Archiv wird an seiner Stelle
entpackt, und bei jedem Fehler wird der alte Cache zurückgeschoben, sodass
eine fehlgeschlagene Wiederherstellung kein funktionierendes Modell
zerstören kann. Wähle eines der vorhandenen Archive in einem Datei-Picker;
die jüngsten stehen oben. Nutze eine Sicherung, bevor du den Cache zum
Speichern von Festplattenspeicher löschst — wiederhergestellt wird später
mit **Modell wiederherstellen …**.

## Deinstallieren

```sh
launchctl bootout gui/$(id -u)/local.splashbar
rm ~/Library/LaunchAgents/local.splashbar.plist /Applications/SplashBar.app
```

## Mitwirken

Siehe [CONTRIBUTING.md](CONTRIBUTING.md). Bug-Reports und Feature-Wünsche
sind willkommen — öffne ein Issue, besonders wenn deine Splash-Installation
an einem anderen Port oder Label liegt.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
