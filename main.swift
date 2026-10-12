import Cocoa

struct SplashBarSettings {
    static let defaultLaunchdLabel = "local.llm.splash"
    static let defaultServerURL = URL(string: "http://127.0.0.1:8080")!
    static let defaultLogPath = NSHomeDirectory() + "/Library/Logs/Splash/splash.log"
    static let defaultRefreshInterval: TimeInterval = 5
    static let defaultRequestTimeout: TimeInterval = 2
    static let defaultIdleThresholdGB = 3.0

    private enum Key {
        static let launchdLabel = "launchdLabel"
        static let serverURL = "serverURL"
        static let agentPlistPath = "agentPlistPath"
        static let logPath = "logPath"
        static let refreshInterval = "refreshInterval"
        static let requestTimeout = "requestTimeout"
        static let idleThresholdGB = "idleThresholdGB"
    }

    var launchdLabel: String
    var serverURL: URL
    var agentPlistPath: String
    var logPath: String
    var refreshInterval: TimeInterval
    var requestTimeout: TimeInterval
    var idleThresholdGB: Double

    init(defaults: UserDefaults = .standard) {
        launchdLabel = defaults.string(forKey: Key.launchdLabel) ?? Self.defaultLaunchdLabel
        serverURL = URL(string: defaults.string(forKey: Key.serverURL) ?? "") ?? Self.defaultServerURL
        agentPlistPath = defaults.string(forKey: Key.agentPlistPath)
            ?? NSHomeDirectory() + "/Library/LaunchAgents/\(launchdLabel).plist"
        logPath = defaults.string(forKey: Key.logPath) ?? Self.defaultLogPath
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Double ?? Self.defaultRefreshInterval
        requestTimeout = defaults.object(forKey: Key.requestTimeout) as? Double ?? Self.defaultRequestTimeout
        idleThresholdGB = defaults.object(forKey: Key.idleThresholdGB) as? Double ?? Self.defaultIdleThresholdGB
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(launchdLabel, forKey: Key.launchdLabel)
        defaults.set(serverURL.absoluteString, forKey: Key.serverURL)
        defaults.set(agentPlistPath, forKey: Key.agentPlistPath)
        defaults.set(logPath, forKey: Key.logPath)
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
        defaults.set(requestTimeout, forKey: Key.requestTimeout)
        defaults.set(idleThresholdGB, forKey: Key.idleThresholdGB)
    }
}

@discardableResult
func sh(_ cmd: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-c", cmd]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    p.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func serverAddress(for url: URL) -> String {
    let host = url.host ?? "Server"
    let displayHost = host.contains(":") ? "[\(host)]" : host
    let defaultPort: Int? = switch url.scheme?.lowercased() {
    case "http": 80
    case "https": 443
    default: nil
    }
    let port = url.port ?? defaultPort
    return port.map { "\(displayHost):\($0)" } ?? displayHost
}

func expandedPath(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

enum ServerState { case running, idle, loading, stopped }

// Splash Engine memory appears in phys_footprint, not RSS.
func footprintGB(_ pid: String) -> Double {
    let out = sh("footprint -p \(shellQuote(pid)) 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'")
    let parts = out.split(separator: " ")
    guard parts.count == 2, let value = Double(parts[0]) else { return 0 }
    switch parts[1] {
    case "GB": return value
    case "MB": return value / 1024
    case "KB": return value / 1048576
    default: return 0
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let uid = getuid()
    var settings = SplashBarSettings()
    var item: NSStatusItem!
    let statusLine = NSMenuItem(title: "Status wird geprüft …", action: nil, keyEquivalent: "")
    let memLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var restartItem: NSMenuItem!
    var timer: Timer?

    var target: String { "gui/\(uid)/\(settings.launchdLabel)" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Splash") {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeft
        }

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        memLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(memLine)
        menu.addItem(.separator())
        startItem = add(menu, "Starten", #selector(start))
        stopItem = add(menu, "Stoppen (RAM freigeben)", #selector(stop))
        restartItem = add(menu, "Neu starten", #selector(restart))
        menu.addItem(.separator())
        _ = add(menu, "Chat im Browser öffnen", #selector(openChat))
        _ = add(menu, "Protokoll anzeigen", #selector(openLog))
        _ = add(menu, "Einstellungen …", #selector(configure))
        menu.addItem(.separator())
        _ = add(menu, "SplashBar beenden", #selector(quit))
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func add(_ menu: NSMenu, _ title: String, _ selector: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        menuItem.target = self
        menu.addItem(menuItem)
        return menuItem
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        let currentSettings = settings
        let serviceTarget = target
        DispatchQueue.global(qos: .utility).async {
            let pid = sh("launchctl print \(shellQuote(serviceTarget)) 2>/dev/null | awk '$1==\"pid\" {print $3; exit}'")
            var state = ServerState.stopped
            var memoryGB: Double = 0
            if !pid.isEmpty {
                let healthURL = currentSettings.serverURL
                    .appendingPathComponent("v1")
                    .appendingPathComponent("models")
                let code = sh("curl -s -m \(shellQuote(String(currentSettings.requestTimeout))) -o /dev/null -w '%{http_code}' \(shellQuote(healthURL.absoluteString))")
                let child = sh("pgrep -P \(shellQuote(pid)) | head -1")
                memoryGB = footprintGB(child.isEmpty ? pid : child)
                if code == "200" {
                    state = memoryGB < currentSettings.idleThresholdGB ? .idle : .running
                } else {
                    state = .loading
                }
            }
            DispatchQueue.main.async { self.apply(state, memoryGB) }
        }
    }

    func apply(_ state: ServerState, _ memoryGB: Double) {
        let color: NSColor
        switch state {
        case .running:
            color = .systemGreen
            statusLine.title = "Splash läuft · \(serverAddress(for: settings.serverURL))"
        case .idle:
            color = .systemBlue
            statusLine.title = "Splash ruht · Modell entladen (lädt bei Anfrage) · ~\(Int(settings.refreshInterval)) s"
        case .loading:
            color = .systemOrange
            statusLine.title = "Splash startet / lädt Modell …"
        case .stopped:
            color = .systemGray
            statusLine.title = "Splash ist gestoppt"
        }
        memLine.title = state == .stopped
            ? "Arbeitsspeicher: frei"
            : String(format: "Arbeitsspeicher: %.1f GB", memoryGB)
        item.button?.attributedTitle = NSAttributedString(string: " ●", attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 9)
        ])
        startItem.isEnabled = state == .stopped
        stopItem.isEnabled = state != .stopped
        restartItem.isEnabled = state != .stopped
    }

    func isLoaded() -> Bool {
        !sh("launchctl print \(shellQuote(target)) >/dev/null 2>&1 && echo yes").isEmpty
    }

    @objc func start() {
        DispatchQueue.global().async {
            if self.isLoaded() {
                sh("launchctl kickstart \(shellQuote(self.target))")
            } else {
                sh("launchctl bootstrap gui/\(self.uid) \(shellQuote(expandedPath(self.settings.agentPlistPath)))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        }
    }

    @objc func stop() {
        DispatchQueue.global().async {
            sh("launchctl kill SIGTERM \(shellQuote(self.target))")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        }
    }

    @objc func restart() {
        DispatchQueue.global().async {
            if self.isLoaded() {
                sh("launchctl kickstart -k \(shellQuote(self.target))")
            } else {
                sh("launchctl bootstrap gui/\(self.uid) \(shellQuote(expandedPath(self.settings.agentPlistPath)))")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        }
    }

    @objc func openChat() { NSWorkspace.shared.open(settings.serverURL) }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: expandedPath(settings.logPath)))
    }

    @objc func configure() {
        let alert = NSAlert()
        alert.messageText = "SplashBar Einstellungen"
        alert.informativeText = "Verbindung und Statusanzeige konfigurieren."
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")

        let fields: [(String, NSTextField)] = [
            ("Server-URL", NSTextField(string: settings.serverURL.absoluteString)),
            ("LaunchAgent-Label", NSTextField(string: settings.launchdLabel)),
            ("LaunchAgent-Plist", NSTextField(string: settings.agentPlistPath)),
            ("Protokollpfad", NSTextField(string: settings.logPath)),
            ("Aktualisierung (Sek.)", NSTextField(string: String(settings.refreshInterval))),
            ("API-Timeout (Sek.)", NSTextField(string: String(settings.requestTimeout))),
            ("Idle-Grenze (GB)", NSTextField(string: String(settings.idleThresholdGB)))
        ]

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: CGFloat(fields.count) * 38))
        for (index, entry) in fields.enumerated() {
            let (title, field) = entry
            let y = CGFloat(fields.count - index - 1) * 38 + 6
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y, width: 155, height: 24)
            field.frame = NSRect(x: 162, y: y, width: 350, height: 24)
            form.addSubview(label)
            form.addSubview(field)
        }
        alert.accessoryView = form

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let serverText = fields[0].1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = validatedServerURL(serverText),
              fields[1].1.stringValue.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !fields[2].1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fields[3].1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let refreshInterval = Double(fields[4].1.stringValue), refreshInterval.isFinite,
              refreshInterval >= 1, refreshInterval <= 3600,
              let requestTimeout = Double(fields[5].1.stringValue), requestTimeout.isFinite,
              requestTimeout > 0, requestTimeout <= 60,
              let idleThresholdGB = Double(fields[6].1.stringValue), idleThresholdGB.isFinite,
              idleThresholdGB > 0, idleThresholdGB <= 1024 else {
            showSettingsError()
            return
        }

        var updated = settings
        let oldDefaultPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(settings.launchdLabel).plist"
        updated.launchdLabel = fields[1].1.stringValue
        updated.agentPlistPath = fields[2].1.stringValue
        if updated.agentPlistPath == oldDefaultPlist {
            updated.agentPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(updated.launchdLabel).plist"
        }
        updated.serverURL = serverURL
        updated.logPath = fields[3].1.stringValue
        updated.refreshInterval = refreshInterval
        updated.requestTimeout = requestTimeout
        updated.idleThresholdGB = idleThresholdGB
        updated.save()
        settings = updated
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func validatedServerURL(_ text: String) -> URL? {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        return components.url
    }

    func showSettingsError() {
        let error = NSAlert()
        error.messageText = "Ungültige Einstellungen"
        error.informativeText = "Bitte URL, LaunchAgent-Angaben und positive Zahlenwerte prüfen."
        error.addButton(withTitle: "OK")
        error.runModal()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
