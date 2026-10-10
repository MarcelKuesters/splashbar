import Cocoa

// SplashBar – Menüleisten-Steuerung für den lokalen Splash-Server (Qwen3.8 27B)
let label = "local.llm.splash"
let uid = getuid()
let target = "gui/\(uid)/\(label)"
let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
let logPath = NSHomeDirectory() + "/Library/Logs/Splash/splash.log"
let chatURL = URL(string: "http://127.0.0.1:8080")!

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

enum ServerState { case running, idle, loading, stopped }

// Splash-Engine hält das Modell als GPU-Speicher; RSS zeigt das nicht, phys_footprint schon
func footprintGB(_ pid: String) -> Double {
    let out = sh("footprint -p \(pid) 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'")
    let parts = out.split(separator: " ")
    guard parts.count == 2, let v = Double(parts[0]) else { return 0 }
    switch parts[1] {
    case "GB": return v
    case "MB": return v / 1024
    case "KB": return v / 1048576
    default: return 0
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem!
    let statusLine = NSMenuItem(title: "Status wird geprüft …", action: nil, keyEquivalent: "")
    let memLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var restartItem: NSMenuItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = NSImage(systemSymbolName: "brain", accessibilityDescription: "Splash") {
            img.isTemplate = true
            item.button?.image = img
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
        menu.addItem(.separator())
        _ = add(menu, "SplashBar beenden", #selector(quit))
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func add(_ menu: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
        return mi
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let pid = sh("launchctl print \(target) 2>/dev/null | awk '$1==\"pid\" {print $3; exit}'")
            var state = ServerState.stopped
            var memGB: Double = 0
            if !pid.isEmpty {
                let code = sh("curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/v1/models")
                let child = sh("pgrep -P \(pid) | head -1")
                memGB = footprintGB(child.isEmpty ? pid : child)
                if code == "200" {
                    state = memGB < 3 ? .idle : .running
                } else {
                    state = .loading
                }
            }
            DispatchQueue.main.async { self.apply(state, memGB) }
        }
    }

    func apply(_ state: ServerState, _ memGB: Double) {
        let color: NSColor
        switch state {
        case .running:
            color = .systemGreen
            statusLine.title = "Splash läuft · Qwen3.8 27B · Port 8080"
        case .idle:
            color = .systemBlue
            statusLine.title = "Splash ruht · Modell entladen (lädt bei Anfrage in ~5 s)"
        case .loading:
            color = .systemOrange
            statusLine.title = "Splash startet / lädt Modell …"
        case .stopped:
            color = .systemGray
            statusLine.title = "Splash ist gestoppt"
        }
        memLine.title = state == .stopped ? "Arbeitsspeicher: frei" : String(format: "Arbeitsspeicher: %.1f GB", memGB)
        item.button?.attributedTitle = NSAttributedString(string: " ●", attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 9)
        ])
        startItem.isEnabled = state == .stopped
        stopItem.isEnabled = state != .stopped
        restartItem.isEnabled = state != .stopped
    }

    func isLoaded() -> Bool {
        return !sh("launchctl print \(target) >/dev/null 2>&1 && echo yes").isEmpty
    }

    @objc func start() {
        DispatchQueue.global().async {
            if self.isLoaded() {
                sh("launchctl kickstart \(target)")
            } else {
                sh("launchctl bootstrap gui/\(uid) '\(plistPath)'")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        }
    }

    @objc func stop() {
        DispatchQueue.global().async {
            sh("launchctl kill SIGTERM \(target)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.refresh() }
        }
    }

    @objc func restart() {
        DispatchQueue.global().async {
            if self.isLoaded() {
                sh("launchctl kickstart -k \(target)")
            } else {
                sh("launchctl bootstrap gui/\(uid) '\(plistPath)'")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        }
    }

    @objc func openChat() { NSWorkspace.shared.open(chatURL) }

    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
