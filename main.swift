import Cocoa

struct SplashBarSettings {
    static let defaultLaunchdLabel = "local.llm.splash"
    static let defaultServerURL = URL(string: "http://127.0.0.1:8080")!
    static let defaultLogPath = NSHomeDirectory() + "/Library/Logs/Splash/splash.log"
    static let defaultRefreshInterval: TimeInterval = 5
    static let defaultRequestTimeout: TimeInterval = 2
    static let defaultIdleThresholdGB = 3.0
    static let defaultModelID = ""

    private enum Key {
        static let launchdLabel = "launchdLabel"
        static let serverURL = "serverURL"
        static let agentPlistPath = "agentPlistPath"
        static let logPath = "logPath"
        static let refreshInterval = "refreshInterval"
        static let requestTimeout = "requestTimeout"
        static let idleThresholdGB = "idleThresholdGB"
        static let modelID = "modelID"
        static let additionalModelsPath = "additionalModelsPath"
    }

    var launchdLabel: String
    var serverURL: URL
    var agentPlistPath: String
    var logPath: String
    var refreshInterval: TimeInterval
    var requestTimeout: TimeInterval
    var idleThresholdGB: Double
    var modelID: String
    var additionalModelsPath: String

    init(defaults: UserDefaults = .standard) {
        launchdLabel = defaults.string(forKey: Key.launchdLabel) ?? Self.defaultLaunchdLabel
        serverURL = URL(string: defaults.string(forKey: Key.serverURL) ?? "") ?? Self.defaultServerURL
        agentPlistPath = defaults.string(forKey: Key.agentPlistPath)
            ?? NSHomeDirectory() + "/Library/LaunchAgents/\(launchdLabel).plist"
        logPath = defaults.string(forKey: Key.logPath) ?? Self.defaultLogPath
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Double ?? Self.defaultRefreshInterval
        requestTimeout = defaults.object(forKey: Key.requestTimeout) as? Double ?? Self.defaultRequestTimeout
        idleThresholdGB = defaults.object(forKey: Key.idleThresholdGB) as? Double ?? Self.defaultIdleThresholdGB
        modelID = defaults.string(forKey: Key.modelID) ?? Self.defaultModelID
        additionalModelsPath = defaults.string(forKey: Key.additionalModelsPath) ?? ""
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(launchdLabel, forKey: Key.launchdLabel)
        defaults.set(serverURL.absoluteString, forKey: Key.serverURL)
        defaults.set(agentPlistPath, forKey: Key.agentPlistPath)
        defaults.set(logPath, forKey: Key.logPath)
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
        defaults.set(requestTimeout, forKey: Key.requestTimeout)
        defaults.set(idleThresholdGB, forKey: Key.idleThresholdGB)
        defaults.set(modelID, forKey: Key.modelID)
        defaults.set(additionalModelsPath, forKey: Key.additionalModelsPath)
    }
}

struct CommandResult {
    var status: Int32
    var output: String
}

final class VersionChangeDiagnostics {
    private let lock = NSLock()
    private var fileURL: URL?

    func begin(version: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/SplashBar", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let suffix = String(UUID().uuidString.prefix(8))
            let url = directory.appendingPathComponent("version-change-\(timestamp)-\(suffix).log")
            let header = "SplashBar version change to \(version)\nStarted: \(Date())\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
            try header.write(to: url, atomically: true, encoding: .utf8)
            fileURL = url
            return url
        } catch {
            fileURL = nil
            return nil
        }
    }

    func record(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let fileURL, let data = (text + "\n").data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }

    func currentURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return fileURL
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        fileURL = nil
    }
}

let versionChangeDiagnostics = VersionChangeDiagnostics()

struct SplashRelease {
    var version: String
    var archiveURL: String
    var checksumURL: String
}

struct LocalModel {
    var id: String
    var source: String
}

final class ModelSelectionCoordinator: NSObject, NSTextFieldDelegate {
    let compatibleField: NSComboBox
    let otherField: NSComboBox
    let customField: NSTextField

    init(compatibleField: NSComboBox, otherField: NSComboBox, customField: NSTextField) {
        self.compatibleField = compatibleField
        self.otherField = otherField
        self.customField = customField
    }

    @objc func modelListChanged(_ sender: NSComboBox) {
        if sender === compatibleField {
            clearSelection(in: otherField)
            customField.stringValue = ""
        } else {
            clearSelection(in: compatibleField)
            customField.stringValue = ""
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        clearSelection(in: compatibleField)
        clearSelection(in: otherField)
    }

    private func clearSelection(in field: NSComboBox) {
        let selectedIndex = field.indexOfSelectedItem
        if selectedIndex >= 0 { field.deselectItem(at: selectedIndex) }
        field.stringValue = ""
    }
}

let suggestedModelIDs = [
    "mlx-community/Qwen3.8-27B-4bit",
    "mlx-community/Qwen3.6-35B-A3B-4bit",
    "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M",
    "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M"
]

func versionComponents(_ version: String) -> [Int]? {
    guard let range = version.range(of: #"\d+(?:\.\d+){1,2}"#, options: .regularExpression) else { return nil }
    let parts = version[range].split(separator: ".").compactMap { Int($0) }
    return parts.isEmpty ? nil : parts
}

func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
    guard let left = versionComponents(lhs), let right = versionComponents(rhs) else { return nil }
    for index in 0..<max(left.count, right.count) {
        let l = index < left.count ? left[index] : 0
        let r = index < right.count ? right[index] : 0
        if l < r { return .orderedAscending }
        if l > r { return .orderedDescending }
    }
    return .orderedSame
}

func compatibilityLabel(for modelID: String, splashVersion: String) -> String {
    guard versionComponents(splashVersion) != nil else { return tr("model.compat.unknown") }
    if modelID.hasSuffix("-Splash") {
        return compareVersions(splashVersion, "1.3.0") != .orderedDescending
            ? tr("model.compat.until")
            : tr("model.compat.incompat")
    }
    if suggestedModelIDs.contains(modelID) {
        return compareVersions(splashVersion, "1.1.0") != .orderedAscending
            ? tr("model.compat.ok")
            : tr("model.compat.unverified")
    }
    return tr("model.compat.unknown")
}

func modelPayloadExists(in directory: URL) -> Bool {
    guard let children = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return false }
    func isPayload(_ child: URL) -> Bool {
        let ext = child.pathExtension.lowercased()
        if ["gguf", "safetensors", "mlx", "bin", "onnx"].contains(ext) { return true }
        if child.lastPathComponent == "config.json" || child.lastPathComponent == "model.safetensors.index.json" { return true }
        return false
    }
    if children.contains(where: isPayload) { return true }
    // LM Studio stores some Splash-era packages in target/ and draft/ subfolders.
    for child in children {
        guard ["target", "draft", "weights", "model"].contains(child.lastPathComponent.lowercased()) else { continue }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue,
           let nested = try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
           nested.contains(where: isPayload) {
            return true
        }
    }
    return false
}

func localModels(in rootPath: String, source: String) -> [LocalModel] {
    let root = URL(fileURLWithPath: expandedPath(rootPath), isDirectory: true).standardizedFileURL
    guard FileManager.default.fileExists(atPath: root.path) else { return [] }
    var found: [LocalModel] = []
    var visited = Set<String>()

    func add(_ id: String) {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*(?::[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil,
              visited.insert(id).inserted else { return }
        found.append(LocalModel(id: id, source: source))
    }

    if root.lastPathComponent.hasPrefix("models--") {
        let components = root.lastPathComponent.replacingOccurrences(of: "models--", with: "").components(separatedBy: "--")
        if components.count >= 2 && modelPayloadExists(in: root) {
            add("\(components[0])/\(components.dropFirst().joined(separator: "--"))")
        }
    } else if modelPayloadExists(in: root) {
        let parts = root.pathComponents
        if parts.count >= 2 { add("\(parts[parts.count - 2])/\(parts[parts.count - 1])") }
    }

    // Hugging Face Hub cache: models--publisher--repository/snapshots/<revision>/...
    if let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
        for entry in entries where entry.lastPathComponent.hasPrefix("models--") {
            let components = entry.lastPathComponent
                .replacingOccurrences(of: "models--", with: "")
                .components(separatedBy: "--")
            guard components.count >= 2 else { continue }
            let snapshots = entry.appendingPathComponent("snapshots", isDirectory: true)
            let hasSnapshot = ((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []).contains {
                modelPayloadExists(in: snapshots.appendingPathComponent($0, isDirectory: true))
            }
            if hasSnapshot { add("\(components[0])/\(components.dropFirst().joined(separator: "--"))") }
        }
    }

    // LM Studio and custom roots: publisher/repository/weights (or a direct model folder).
    let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    )
    while let item = enumerator?.nextObject() as? URL {
        if item.pathComponents.contains(where: { $0.hasPrefix("models--") }) {
            enumerator?.skipDescendants()
            continue
        }
        let depth = item.pathComponents.count - root.pathComponents.count
        guard depth >= 2 else { continue }
        guard depth <= 4 else {
            enumerator?.skipDescendants()
            continue
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
        if modelPayloadExists(in: item) {
            let relative = item.pathComponents.dropFirst(root.pathComponents.count)
            let parts = Array(relative)
            if parts.count >= 2 {
                add("\(parts[parts.count - 2])/\(parts[parts.count - 1])")
            } else if parts.count == 1 {
                let parent = root.lastPathComponent
                if parent.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil {
                    add("\(parent)/\(parts[0])")
                }
            }
            enumerator?.skipDescendants()
        }
    }
    return found
}

func availableLocalModels(additionalPath: String) -> [LocalModel] {
    var paths: [(String, String)] = []
    if let cache = ProcessInfo.processInfo.environment["HF_HUB_CACHE"], !cache.isEmpty {
        paths.append((cache, "Hugging Face"))
    } else if let home = ProcessInfo.processInfo.environment["HF_HOME"], !home.isEmpty {
        paths.append((URL(fileURLWithPath: home).appendingPathComponent("hub").path, "Hugging Face"))
    }
    paths.append((NSHomeDirectory() + "/.cache/huggingface/hub", "Splash / Hugging Face"))
    paths.append((NSHomeDirectory() + "/.lmstudio/models", "LM Studio"))
    if !additionalPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        paths.append((additionalPath, tr("model.source.additional")))
    }

    var results: [LocalModel] = []
    var seen = Set<String>()
    for (path, source) in paths {
        for model in localModels(in: path, source: source) where seen.insert(model.id).inserted {
            results.append(model)
        }
    }
    return results.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
}

func availableModelChoices(additionalPath: String, splashVersion: String, preserving selectedModelID: String?) -> (compatible: [String], other: [String]) {
    var models = availableLocalModels(additionalPath: additionalPath)
    for id in suggestedModelIDs where !models.contains(where: { $0.id == id }) {
        models.append(LocalModel(id: id, source: tr("model.source.suggested")))
    }
    if let selectedModelID, !selectedModelID.isEmpty, !models.contains(where: { $0.id == selectedModelID }) {
        models.append(LocalModel(id: selectedModelID, source: tr("model.source.selected")))
    }

    let orderedModels = models.sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    let compatible = orderedModels.filter {
        compatibilityLabel(for: $0.id, splashVersion: splashVersion).hasPrefix("✓")
    }.map(\.id)
    let other = orderedModels.filter {
        !compatibilityLabel(for: $0.id, splashVersion: splashVersion).hasPrefix("✓")
    }.map(\.id)
    return (compatible, other)
}

func runCommand(_ executable: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("splashbar-command-\(UUID().uuidString).log")
    guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
          let outputFile = try? FileHandle(forWritingTo: outputURL) else {
        return CommandResult(status: -1, output: "Could not create command output file")
    }
    defer { try? FileManager.default.removeItem(at: outputURL) }
    process.standardOutput = outputFile
    process.standardError = outputFile

    do {
        try process.run()
        process.waitUntilExit()
        try outputFile.close()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        versionChangeDiagnostics.record("$ \(executable) \(arguments.map(shellQuote).joined(separator: " "))\nexit status: \(process.terminationStatus)\n\(output)")
        return CommandResult(status: process.terminationStatus, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    } catch {
        try? outputFile.close()
        let message = error.localizedDescription
        versionChangeDiagnostics.record("$ \(executable) \(arguments.map(shellQuote).joined(separator: " "))\nprocess launch error: \(message)")
        return CommandResult(status: -1, output: message)
    }
}

func executablePath(_ name: String, candidates: [String]) -> String? {
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return found
    }
    let found = sh("command -v \(shellQuote(name))")
    return found.isEmpty ? nil : found
}

func splashExecutablePath() -> String? {
    executablePath("splash", candidates: ["/opt/homebrew/bin/splash", "/usr/local/bin/splash"])
}

// Localizes a key from the app's .lproj resources. The development language is
// German; if the user's system language has no translation file, AppKit falls
// back to it automatically (see CFBundleDevelopmentRegion in Info.plist).
// Missing keys resolve to the key itself, which keeps gaps visible.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    return String(format: format, locale: Locale.current, arguments: args)
}

func brewExecutablePath() -> String? {
    executablePath("brew", candidates: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"])
}

func availableSplashReleases() -> [SplashRelease] {
    var releases: [SplashRelease] = []
    for page in 1...10 {
        let url = "https://api.github.com/repos/incoai/splash/releases?per_page=100&page=\(page)"
        let response = runCommand("/usr/bin/curl", [
            "--fail", "--silent", "--show-error", "--location",
            "--header", "Accept: application/vnd.github+json",
            "--header", "X-GitHub-Api-Version: 2022-11-28",
            url
        ])
        guard response.status == 0,
              let data = response.output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        if entries.isEmpty { break }

        for entry in entries where (entry["draft"] as? Bool) != true && (entry["prerelease"] as? Bool) != true {
            guard let version = entry["tag_name"] as? String,
                  version.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil,
                  let assets = entry["assets"] as? [[String: Any]] else { continue }
            let archiveName = "splash-\(version)-arm64-macos26.tar.gz"
            guard let archive = assets.first(where: { $0["name"] as? String == archiveName })?["browser_download_url"] as? String,
                  let checksum = assets.first(where: { $0["name"] as? String == archiveName + ".sha256" })?["browser_download_url"] as? String,
                  archive.hasPrefix("https://github.com/incoai/splash/releases/download/"),
                  checksum.hasPrefix("https://github.com/incoai/splash/releases/download/") else { continue }
            releases.append(SplashRelease(version: version, archiveURL: archive, checksumURL: checksum))
        }
        if entries.count < 100 { break }
    }

    return releases.sorted { lhs, rhs in
        let left = lhs.version.split(separator: ".").compactMap { Int($0) }
        let right = rhs.version.split(separator: ".").compactMap { Int($0) }
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart > rightPart }
        }
        return lhs.version > rhs.version
    }
}

func splashVersion() -> String {
    guard let executable = splashExecutablePath() else { return tr("model.notinstalled") }
    let result = runCommand(executable, ["--version"])
    return result.status == 0 ? result.output : tr("model.versionunknown")
}

func readAgentPlist(at path: String) -> [String: Any]? {
    let url = URL(fileURLWithPath: expandedPath(path))
    guard let data = try? Data(contentsOf: url),
          let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
        return nil
    }
    return value as? [String: Any]
}

func modelID(in arguments: [String]) -> String? {
    if let index = arguments.firstIndex(of: "--model"), arguments.indices.contains(index + 1) {
        return arguments[index + 1]
    }
    return arguments.first(where: { $0.hasPrefix("--model=") })?.components(separatedBy: "=").dropFirst().joined(separator: "=")
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
    let statusLine = NSMenuItem(title: tr("status.checking"), action: nil, keyEquivalent: "")
    let modelLine = NSMenuItem(title: tr("status.modelchecking"), action: nil, keyEquivalent: "")
    let memLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let versionLine = NSMenuItem(title: tr("status.versionchecking"), action: nil, keyEquivalent: "")
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var restartItem: NSMenuItem!
    var versionItem: NSMenuItem!
    var timer: Timer?
    var isUpdatingSplash = false
    var versionProgressWindow: NSWindow?
    var versionProgressText: NSTextField?
    var versionProgressSpinner: NSProgressIndicator?
    var versionLogButton: NSButton?
    var versionCloseButton: NSButton?
    var versionProgressLogURL: URL?
    var activeModalAlertWindow: NSWindow?
    var additionalModelsPathField: NSTextField?
    var compatibleModelsField: NSComboBox?
    var otherModelsField: NSComboBox?
    var customModelIDField: NSTextField?
    var settingsSplashVersion = "?"

    var target: String { "gui/\(uid)/\(settings.launchdLabel)" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let arguments = readAgentPlist(at: settings.agentPlistPath)?["ProgramArguments"] as? [String],
           let configuredModel = modelID(in: arguments), configuredModel != settings.modelID {
            settings.modelID = configuredModel
            settings.save()
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Splash") {
            image.isTemplate = true
            item.button?.image = image
            item.button?.imagePosition = .imageLeft
        }

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        modelLine.isEnabled = false
        memLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(modelLine)
        menu.addItem(memLine)
        menu.addItem(versionLine)
        menu.addItem(.separator())
        startItem = add(menu, tr("menu.start"), #selector(start))
        stopItem = add(menu, tr("menu.stop"), #selector(stop))
        restartItem = add(menu, tr("menu.restart"), #selector(restart))
        menu.addItem(.separator())
        _ = add(menu, tr("menu.chat"), #selector(openChat))
        _ = add(menu, tr("menu.log"), #selector(openLog))
        _ = add(menu, tr("menu.settings"), #selector(configure))
        versionItem = add(menu, tr("menu.version"), #selector(chooseSplashVersion))
        menu.addItem(.separator())
        _ = add(menu, tr("menu.quit"), #selector(quit))
        item.menu = menu
        refresh()
        refreshSplashVersion()
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
            var model = ""
            if !pid.isEmpty {
                let healthURL = currentSettings.serverURL
                    .appendingPathComponent("v1")
                    .appendingPathComponent("models")
                let code = sh("curl -s -m \(shellQuote(String(currentSettings.requestTimeout))) -o /dev/null -w '%{http_code}' \(shellQuote(healthURL.absoluteString))")
                let child = sh("pgrep -P \(shellQuote(pid)) | head -1")
                memoryGB = footprintGB(child.isEmpty ? pid : child)
                model = self.currentModel(healthURL, timeout: currentSettings.requestTimeout)
                if code == "200" {
                    state = memoryGB < currentSettings.idleThresholdGB ? .idle : .running
                } else {
                    state = .loading
                }
            }
            DispatchQueue.main.async { self.apply(state, memoryGB, model) }
        }
    }

    /// Liest das gerade geladene Modell vom Server (z. B. "mlx-community/Qwen3.8-27B-4bit")
    /// und hält die Menüzeile mit einer Kürzung auf 34 Zeichen schmal.
    func currentModel(_ url: URL, timeout: TimeInterval) -> String {
        let raw = sh("curl -s -m \(shellQuote(String(timeout))) \(shellQuote(url.absoluteString))")
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return "" }
        if let entries = dict["data"] as? [[String: Any]] {
            if let id = entries.first?["id"] as? String, !id.isEmpty { return truncate(id) }
        }
        if let models = dict["models"] as? [[String: Any]] {
            if let name = models.first?["name"] as? String, !name.isEmpty { return truncate(name) }
        }
        return ""
    }

    /// Hält die Menüzeile schmal: IDs länger als 34 Zeichen werden gekürzt.
    private func truncate(_ s: String) -> String {
        return s.count <= 34 ? s : String(s.prefix(33)) + "…"
    }

    func apply(_ state: ServerState, _ memoryGB: Double, _ model: String = "") {
        let color: NSColor
        switch state {
        case .running:
            color = .systemGreen
            statusLine.title = tr("status.running", serverAddress(for: settings.serverURL))
        case .idle:
            color = .systemBlue
            statusLine.title = tr("status.idle", Int(settings.refreshInterval))
        case .loading:
            color = .systemOrange
            statusLine.title = tr("status.loading")
        case .stopped:
            color = .systemGray
            statusLine.title = tr("status.stopped")
        }
        memLine.title = state == .stopped
            ? tr("status.memfree")
            : tr("status.mem", memoryGB)
        modelLine.title = model.isEmpty
            ? tr("status.modelnone")
            : tr("status.model", model)
        item.button?.attributedTitle = NSAttributedString(string: " ●", attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: 9)
        ])
        startItem.isEnabled = state == .stopped && !isUpdatingSplash
        stopItem.isEnabled = state != .stopped && !isUpdatingSplash
        restartItem.isEnabled = state != .stopped && !isUpdatingSplash
        versionItem.isEnabled = !isUpdatingSplash && brewExecutablePath() != nil
    }

    func refreshSplashVersion() {
        DispatchQueue.global(qos: .utility).async {
            let version = splashVersion()
            DispatchQueue.main.async {
                self.versionLine.title = tr("status.version", version)
            }
        }
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
        let currentSplashVersion = splashVersion()
        let alert = NSAlert()
        alert.messageText = tr("settings.title")
        alert.informativeText = tr("settings.info", currentSplashVersion)
        alert.addButton(withTitle: tr("settings.save"))
        alert.addButton(withTitle: tr("settings.cancel"))

        let compatibleModelField = NSComboBox()
        let otherModelField = NSComboBox()
        let customModelField = NSTextField(string: "")
        let additionalPathField = NSTextField(string: settings.additionalModelsPath)
        compatibleModelField.isEditable = false
        otherModelField.isEditable = false
        compatibleModelsField = compatibleModelField
        otherModelsField = otherModelField
        customModelIDField = customModelField
        settingsSplashVersion = currentSplashVersion
        refreshModelLists(additionalPath: settings.additionalModelsPath, preserving: settings.modelID)

        let modelSelectionCoordinator = ModelSelectionCoordinator(
            compatibleField: compatibleModelField,
            otherField: otherModelField,
            customField: customModelField
        )
        compatibleModelField.target = modelSelectionCoordinator
        compatibleModelField.action = #selector(ModelSelectionCoordinator.modelListChanged(_:))
        otherModelField.target = modelSelectionCoordinator
        otherModelField.action = #selector(ModelSelectionCoordinator.modelListChanged(_:))
        customModelField.delegate = modelSelectionCoordinator

        let fields: [(String, NSTextField)] = [
            (tr("settings.field.url"), NSTextField(string: settings.serverURL.absoluteString)),
            (tr("settings.field.compatible", currentSplashVersion), compatibleModelField),
            (tr("settings.field.other"), otherModelField),
            (tr("settings.field.custom"), customModelField),
            (tr("settings.field.agent"), NSTextField(string: settings.launchdLabel)),
            (tr("settings.field.plist"), NSTextField(string: settings.agentPlistPath)),
            (tr("settings.field.log"), NSTextField(string: settings.logPath)),
            (tr("settings.field.refresh"), NSTextField(string: String(settings.refreshInterval))),
            (tr("settings.field.timeout"), NSTextField(string: String(settings.requestTimeout))),
            (tr("settings.field.idle"), NSTextField(string: String(settings.idleThresholdGB))),
            (tr("settings.field.addpath"), additionalPathField)
        ]

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: CGFloat(fields.count) * 38))
        for (index, entry) in fields.enumerated() {
            let (title, field) = entry
            let y = CGFloat(fields.count - index - 1) * 38 + 6
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y, width: 230, height: 24)
            field.frame = NSRect(x: 237, y: y, width: index == 10 ? 385 : 475, height: 24)
            form.addSubview(label)
            form.addSubview(field)
        }

        additionalModelsPathField = additionalPathField
        let browseButton = NSButton(title: tr("settings.browse"), target: self, action: #selector(chooseAdditionalModelsPath(_:)))
        browseButton.frame = NSRect(x: 630, y: 6, width: 82, height: 24)
        browseButton.bezelStyle = .rounded
        form.addSubview(browseButton)
        alert.accessoryView = form

        guard runClosableAlert(alert) == .alertFirstButtonReturn else { return }

        let serverText = fields[0].1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedModel = [compatibleModelField, otherModelField]
            .map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? customModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalModelsPath = fields[10].1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = validatedServerURL(serverText),
              requestedModel.isEmpty || validatedModelID(requestedModel),
              fields[4].1.stringValue.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !fields[5].1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fields[6].1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let refreshInterval = Double(fields[7].1.stringValue), refreshInterval.isFinite,
              refreshInterval >= 1, refreshInterval <= 3600,
              let requestTimeout = Double(fields[8].1.stringValue), requestTimeout.isFinite,
              requestTimeout > 0, requestTimeout <= 60,
              let idleThresholdGB = Double(fields[9].1.stringValue), idleThresholdGB.isFinite,
              idleThresholdGB > 0, idleThresholdGB <= 1024 else {
            showSettingsError()
            return
        }

        var updated = settings
        let oldDefaultPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(settings.launchdLabel).plist"
        updated.launchdLabel = fields[4].1.stringValue
        updated.agentPlistPath = fields[5].1.stringValue
        if updated.agentPlistPath == oldDefaultPlist {
            updated.agentPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(updated.launchdLabel).plist"
        }
        updated.serverURL = serverURL
        updated.logPath = fields[6].1.stringValue
        updated.refreshInterval = refreshInterval
        updated.requestTimeout = requestTimeout
        updated.idleThresholdGB = idleThresholdGB
        updated.additionalModelsPath = additionalModelsPath
        if !requestedModel.isEmpty {
            let currentAgentModel = (readAgentPlist(at: updated.agentPlistPath)?["ProgramArguments"] as? [String])
                .flatMap { modelID(in: $0) }
            let modelChanged = requestedModel != currentAgentModel
            if modelChanged {
                guard isLocalServerURL(serverURL) else {
                    showSettingsError(tr("settings.error.agent"))
                    return
                }
                let oldTarget = "gui/\(uid)/\(settings.launchdLabel)"
                let serviceLoaded = !sh("launchctl print \(shellQuote(oldTarget)) >/dev/null 2>&1 && echo yes").isEmpty
                if serviceLoaded {
                    let restartAlert = NSAlert()
                    restartAlert.messageText = tr("model.restart")
                    restartAlert.informativeText = tr("model.restart.detail")
                    restartAlert.addButton(withTitle: tr("model.restart.switch"))
                    restartAlert.addButton(withTitle: "Abbrechen")
                    guard runClosableAlert(restartAlert) == .alertFirstButtonReturn else { return }
                }

                if let error = applyModelSelection(
                    requestedModel,
                    settings: updated,
                    previousSettings: settings,
                    restartLoadedService: serviceLoaded
                ) {
                    showSettingsError(error)
                    return
                }
                updated.modelID = requestedModel
            }
        }

        updated.save()
        settings = updated
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func validatedModelID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*(?::[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil
            && !text.split(separator: "/").contains("..")
    }

    func isLocalServerURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    func applyModelSelection(
        _ selectedModel: String,
        settings updatedSettings: SplashBarSettings,
        previousSettings: SplashBarSettings,
        restartLoadedService: Bool
    ) -> String? {
        let path = expandedPath(updatedSettings.agentPlistPath)
        let oldPath = expandedPath(previousSettings.agentPlistPath)
        if restartLoadedService && path != oldPath {
            return tr("validate.labelfirst")
        }

        let fileManager = FileManager.default
        let plistURL = URL(fileURLWithPath: path)
        let oldData = try? Data(contentsOf: plistURL)
        var plist: [String: Any] = [:]
        if let oldData {
            guard let value = try? PropertyListSerialization.propertyList(from: oldData, options: [], format: nil),
                  let dictionary = value as? [String: Any] else {
                return tr("validate.plist")
            }
            plist = dictionary
        }

        var arguments = plist["ProgramArguments"] as? [String] ?? []
        if arguments.isEmpty {
            guard let splashPath = splashExecutablePath() else {
                return tr("validate.noagent")
            }
            let port = updatedSettings.serverURL.port ?? 8080
            arguments = [splashPath, "serve", "--port", String(port)]
        } else if !arguments.contains("serve") && !arguments.contains(where: { URL(fileURLWithPath: $0).lastPathComponent == "splash" }) {
            return tr("validate.badplist")
        }

        let port = String(updatedSettings.serverURL.port ?? 8080)
        if let index = arguments.firstIndex(of: "--port"), arguments.indices.contains(index + 1) {
            arguments[index + 1] = port
        } else if let index = arguments.firstIndex(where: { $0.hasPrefix("--port=") }) {
            arguments[index] = "--port=\(port)"
        } else {
            arguments += ["--port", port]
        }

        if let index = arguments.firstIndex(of: "--model"), arguments.indices.contains(index + 1) {
            arguments[index + 1] = selectedModel
        } else if let index = arguments.firstIndex(where: { $0.hasPrefix("--model=") }) {
            arguments[index] = "--model=\(selectedModel)"
        } else {
            arguments += ["--model", selectedModel]
        }

        plist["Label"] = updatedSettings.launchdLabel
        plist["ProgramArguments"] = arguments
        plist["RunAtLoad"] = true
        plist["KeepAlive"] = false
        plist["ProcessType"] = "Interactive"
        plist["StandardOutPath"] = expandedPath(updatedSettings.logPath)
        plist["StandardErrorPath"] = expandedPath(updatedSettings.logPath)

        let oldTarget = "gui/\(uid)/\(previousSettings.launchdLabel)"
        let newTarget = "gui/\(uid)/\(updatedSettings.launchdLabel)"
        if newTarget != oldTarget && !sh("launchctl print \(shellQuote(newTarget)) >/dev/null 2>&1 && echo yes").isEmpty {
            return tr("validate.labeltaken")
        }

        if restartLoadedService {
            let stopped = runCommand("/bin/launchctl", ["bootout", oldTarget])
            guard stopped.status == 0 else {
                return tr("validate.stopfailed", stopped.output)
            }
        }

        do {
            try fileManager.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let logURL = URL(fileURLWithPath: expandedPath(updatedSettings.logPath))
            try fileManager.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            if restartLoadedService {
                _ = runCommand("/bin/launchctl", ["bootstrap", "gui/\(uid)", oldPath])
            }
            return tr("validate.savfailed", error.localizedDescription)
        }

        guard restartLoadedService else { return nil }
        let started = runCommand("/bin/launchctl", ["bootstrap", "gui/\(uid)", path])
        guard started.status == 0 else {
            if let oldData {
                try? oldData.write(to: plistURL, options: .atomic)
            } else {
                try? fileManager.removeItem(at: plistURL)
            }
            _ = runCommand("/bin/launchctl", ["bootstrap", "gui/\(uid)", oldPath])
            return tr("validate.startfailed", started.output)
        }
        return nil
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

    func showSettingsError(_ message: String = tr("settings.invalid.detail")) {
        let error = NSAlert()
        error.messageText = tr("settings.invalid")
        error.informativeText = message
        error.addButton(withTitle: tr("settings.ok"))
        _ = runClosableAlert(error)
    }

    func runClosableAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let window = alert.window
        window.styleMask.insert(.closable)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        if let closeButton = window.standardWindowButton(.closeButton) {
            closeButton.isHidden = false
            closeButton.isEnabled = true
            closeButton.target = self
            closeButton.action = #selector(closeModalAlert(_:))
        }
        activeModalAlertWindow = window
        let response = alert.runModal()
        activeModalAlertWindow = nil
        return response
    }

    @objc func closeModalAlert(_ sender: NSButton) {
        let window = sender.window ?? activeModalAlertWindow
        NSApp.stopModal(withCode: .alertSecondButtonReturn)
        window?.orderOut(nil)
    }

    @objc func chooseAdditionalModelsPath(_ sender: NSButton) {
        guard let field = additionalModelsPathField else { return }
        let panel = NSOpenPanel()
        panel.title = tr("model.pick.title")
        panel.message = tr("model.pick.message")
        panel.prompt = tr("model.pick.prompt")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let currentPath = expandedPath(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        var isDirectory: ObjCBool = false
        if !currentPath.isEmpty,
           FileManager.default.fileExists(atPath: currentPath, isDirectory: &isDirectory),
           isDirectory.boolValue {
            panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        } else {
            panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }

        if panel.runModal() == .OK, let selectedURL = panel.url {
            field.stringValue = selectedURL.path
            refreshModelLists(additionalPath: selectedURL.path, preserving: currentSelectedModelID())
        }
    }

    func currentSelectedModelID() -> String? {
        [compatibleModelsField?.stringValue, otherModelsField?.stringValue, customModelIDField?.stringValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    func refreshModelLists(additionalPath: String, preserving selectedModelID: String?) {
        guard let compatibleField = compatibleModelsField,
              let otherField = otherModelsField,
              let customField = customModelIDField else { return }

        let choices = availableModelChoices(
            additionalPath: additionalPath,
            splashVersion: settingsSplashVersion,
            preserving: selectedModelID
        )
        compatibleField.removeAllItems()
        otherField.removeAllItems()
        compatibleField.addItems(withObjectValues: choices.compatible)
        otherField.addItems(withObjectValues: choices.other)
        compatibleField.placeholderString = tr("model.placeholder")
        otherField.placeholderString = tr("model.placeholder")
        compatibleField.stringValue = ""
        otherField.stringValue = ""
        customField.stringValue = ""

        guard let selectedModelID, !selectedModelID.isEmpty else { return }
        if choices.compatible.contains(selectedModelID) {
            compatibleField.selectItem(withObjectValue: selectedModelID)
        } else if choices.other.contains(selectedModelID) {
            otherField.selectItem(withObjectValue: selectedModelID)
        } else {
            customField.stringValue = selectedModelID
        }
    }

    @objc func chooseSplashVersion() {
        guard let brew = brewExecutablePath() else {
            showSettingsError(tr("settings.error.brew"))
            return
        }

        isUpdatingSplash = true
        statusLine.title = tr("status.searchingreleases")
        versionItem.isEnabled = false
        startItem.isEnabled = false
        stopItem.isEnabled = false
        restartItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let releases = availableSplashReleases()
            DispatchQueue.main.async {
                guard !releases.isEmpty else {
                    self.finishVersionChange()
                    self.showSettingsError(tr("settings.error.releases"))
                    return
                }

                let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 310, height: 28), pullsDown: false)
                selector.addItems(withTitles: releases.map(\.version))
                let installedVersion = splashVersion().replacingOccurrences(of: "Splash ", with: "")
                if releases.contains(where: { $0.version == installedVersion }) {
                    selector.selectItem(withTitle: installedVersion)
                }

                let alert = NSAlert()
                alert.messageText = tr("version.pick.title")
                let details = tr("version.pick.detail", splashVersion())
                alert.informativeText = details
                alert.accessoryView = selector
                alert.addButton(withTitle: tr("version.switch"))
                alert.addButton(withTitle: tr("settings.cancel"))
                guard self.runClosableAlert(alert) == .alertFirstButtonReturn else {
                    self.finishVersionChange()
                    return
                }
                let selectedVersion = selector.titleOfSelectedItem ?? releases[0].version
                self.installSplashVersion(selectedVersion, releases: releases, using: brew)
            }
        }
    }

    func servicePID(_ serviceTarget: String) -> String? {
        let result = runCommand("/bin/launchctl", ["print", serviceTarget])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", Int(parts[1]) != nil {
                return String(parts[1])
            }
        }
        return nil
    }

    func waitForServiceToStop(_ serviceTarget: String, timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if servicePID(serviceTarget) == nil { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return servicePID(serviceTarget) == nil
    }

    func installSplashVersion(_ version: String, releases: [SplashRelease], using brew: String) {
        let logURL = versionChangeDiagnostics.begin(version: version)
        versionChangeDiagnostics.record("Selected Splash version: \(version)")
        showVersionProgress(version: version)

        DispatchQueue.global(qos: .userInitiated).async {
            let serviceTarget = self.target
            let wasLoaded = self.isLoaded()
            let previousVersion = splashVersion()
            let previousFormula = self.linkedSplashFormula(using: brew)
            let targetFormula = "splashbar/splash-versions/splash@\(version)"
            var errorText: String?
            var warningText: String?

            if previousVersion == "Splash \(version)" {
                versionChangeDiagnostics.record("No change: Splash \(version) is already active.")
                versionChangeDiagnostics.record("Application stack trace:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                versionChangeDiagnostics.end()
                DispatchQueue.main.async {
                    self.finishVersionChange()
                    self.completeVersionProgress(message: "Splash \(version) ist bereits aktiv.", logURL: logURL)
                }
                return
            }

            guard let release = releases.first(where: { $0.version == version }) else {
                versionChangeDiagnostics.record("ERROR: Release \(version) was not present in the fetched release list.")
                versionChangeDiagnostics.record("Application stack trace:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                versionChangeDiagnostics.end()
                DispatchQueue.main.async {
                    self.finishVersionChange()
                    self.completeVersionProgress(error: tr("version.error.releasegone"), logURL: logURL)
                }
                return
            }

            if wasLoaded {
                let stopped = runCommand("/bin/launchctl", ["kill", "SIGTERM", serviceTarget])
                if stopped.status != 0 || !self.waitForServiceToStop(serviceTarget) {
                    errorText = tr("version.error.stopstuck", stopped.output)
                }
            }

            var targetAvailable = false
            if errorText == nil {
                let localTap = runCommand(brew, ["--repository", "splashbar/splash-versions"])
                if localTap.status != 0 {
                    let createdTap = runCommand(brew, ["tap-new", "--no-git", "splashbar/splash-versions"])
                    if createdTap.status != 0 {
                        errorText = tr("version.error.tapfailed", createdTap.output)
                    }
                }
                if errorText == nil {
                    let checksum = self.downloadedChecksum(for: release)
                    if checksum == nil || !self.writeReleaseFormula(release, checksum: checksum ?? "", using: brew) {
                        errorText = tr("version.error.checksumfailed", version)
                    }
                }

                if errorText == nil {
                    if let previousFormula, previousFormula != targetFormula {
                        let unlinked = runCommand(brew, ["unlink", previousFormula])
                        if unlinked.status != 0 {
                            errorText = "Die aktive Formel \(previousFormula) konnte vor dem Wechsel nicht getrennt werden:\n\(unlinked.output)"
                        }
                    }
                }

                if errorText == nil {
                    let installed = runCommand(brew, ["list", "--versions", targetFormula])
                    if installed.status != 0 {
                        let install = runCommand(brew, ["install", targetFormula])
                        if install.status != 0 {
                            errorText = "Splash \(version) konnte nicht installiert werden:\n\(install.output)"
                        }
                    }
                }

                if errorText == nil {
                    let linked = runCommand(brew, ["link", "--overwrite", targetFormula])
                    let selectedVersion = splashVersion()
                    targetAvailable = linked.status == 0 || selectedVersion == "Splash \(version)"
                    if !targetAvailable {
                        errorText = "Splash \(version) wurde installiert, aber die aktive Version konnte nicht umgeschaltet werden:\n\(linked.output)"
                    }
                }

                if errorText != nil, let previousFormula, previousFormula != targetFormula {
                    let restored = runCommand(brew, ["link", "--overwrite", previousFormula])
                    if restored.status != 0 {
                        warningText = "Die vorherige Formel \(previousFormula) konnte nicht automatisch wiederhergestellt werden:\n\(restored.output)"
                    }
                }
            }

            var restartText: String?
            if wasLoaded {
                let restarted = runCommand("/bin/launchctl", ["kickstart", "-k", serviceTarget])
                if restarted.status != 0 {
                    restartText = tr("version.error.notstarted", restarted.output)
                }
            }

            let installedVersion = splashVersion()
            versionChangeDiagnostics.record("Previous version: \(previousVersion)")
            versionChangeDiagnostics.record("Installed version after attempt: \(installedVersion)")
            if let warningText { versionChangeDiagnostics.record("WARNING: \(warningText)") }
            if let errorText { versionChangeDiagnostics.record("ERROR: \(errorText)") }
            if let restartText { versionChangeDiagnostics.record("ERROR: \(restartText)") }
            if errorText != nil || restartText != nil {
                versionChangeDiagnostics.record("Application stack trace:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
            }
            versionChangeDiagnostics.end()
            let failureText = [errorText, restartText].compactMap { $0 }.joined(separator: "\n\n")
            DispatchQueue.main.async {
                self.finishVersionChange()
                self.versionLine.title = tr("status.version", installedVersion)
                self.refresh()
                if failureText.isEmpty && targetAvailable {
                    self.completeVersionProgress(message: tr("version.success", installedVersion), logURL: logURL)
                } else {
                    let briefError = restartText != nil
                        ? tr("version.error.restart")
                        : tr("version.error.install")
                    self.completeVersionProgress(error: briefError, logURL: logURL)
                }
            }
        }
    }

    func finishVersionChange() {
        isUpdatingSplash = false
        versionItem.isEnabled = brewExecutablePath() != nil
        refresh()
    }

    func showVersionProgress(version: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("window.title")
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 230))
        let text = NSTextField(wrappingLabelWithString: tr("version.installing", version))
        text.frame = NSRect(x: 24, y: 76, width: 492, height: 130)
        text.font = .systemFont(ofSize: 14)
        content.addSubview(text)

        let spinner = NSProgressIndicator(frame: NSRect(x: 24, y: 38, width: 20, height: 20))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        content.addSubview(spinner)

        let logButton = NSButton(title: tr("version.progresslog"), target: self, action: #selector(openVersionChangeLog))
        logButton.frame = NSRect(x: 268, y: 18, width: 150, height: 28)
        logButton.isHidden = true
        content.addSubview(logButton)

        let closeButton = NSButton(title: tr("settings.close"), target: self, action: #selector(closeVersionProgress))
        closeButton.frame = NSRect(x: 426, y: 18, width: 82, height: 28)
        closeButton.bezelStyle = .rounded
        closeButton.isHidden = true
        content.addSubview(closeButton)

        window.contentView = content
        versionProgressWindow = window
        versionProgressText = text
        versionProgressSpinner = spinner
        versionLogButton = logButton
        versionCloseButton = closeButton
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func completeVersionProgress(message: String? = nil, error: String? = nil, logURL: URL?) {
        versionProgressSpinner?.stopAnimation(nil)
        versionProgressSpinner?.isHidden = true
        versionProgressText?.stringValue = error.map { briefError in
            tr("version.error.text", briefError, logURL?.path ?? tr("version.error.donelog"))
        } ?? (message ?? tr("version.progressdone"))
        versionProgressLogURL = logURL
        versionLogButton?.isHidden = error == nil || logURL == nil
        versionCloseButton?.isHidden = false
        if error != nil, logURL == nil {
            versionProgressText?.stringValue += "\n\n\(tr("version.error.donelog"))"
        }
    }

    @objc func openVersionChangeLog() {
        if let versionProgressLogURL {
            NSWorkspace.shared.open(versionProgressLogURL)
        }
    }

    @objc func closeVersionProgress() {
        versionProgressWindow?.close()
        versionProgressWindow = nil
        versionProgressText = nil
        versionProgressSpinner = nil
        versionLogButton = nil
        versionCloseButton = nil
        versionProgressLogURL = nil
    }

    func downloadedChecksum(for release: SplashRelease) -> String? {
        let checksumFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("splashbar-\(UUID().uuidString).sha256")
        defer { try? FileManager.default.removeItem(at: checksumFile) }

        let download = runCommand("/usr/bin/curl", [
            "--fail", "--silent", "--show-error", "--location",
            "--output", checksumFile.path,
            release.checksumURL
        ])
        guard download.status == 0,
              let contents = try? String(contentsOf: checksumFile, encoding: .utf8),
              let pattern = try? NSRegularExpression(pattern: #"\b([a-fA-F0-9]{64})\b"#),
              let match = pattern.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
              let range = Range(match.range(at: 1), in: contents) else { return nil }
        return String(contents[range]).lowercased()
    }

    func writeReleaseFormula(_ release: SplashRelease, checksum: String, using brew: String) -> Bool {
        guard release.version.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil,
              release.archiveURL.hasPrefix("https://github.com/incoai/splash/releases/download/"),
              checksum.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil else { return false }

        let tap = runCommand(brew, ["--repository", "splashbar/splash-versions"])
        guard tap.status == 0 else { return false }
        let formulaDirectory = URL(fileURLWithPath: tap.output).appendingPathComponent("Formula", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: formulaDirectory, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let classSuffix = release.version.split(separator: ".").joined()
        let formula = """
        class SplashMacOSRequirement < Requirement
          fatal true
          satisfy(build_env: false) { OS.mac? && MacOS.full_version >= "26.4" }

          def message
            "Splash requires macOS 26.4 or newer."
          end
        end

        class SplashAT\(classSuffix) < Formula
          desc "Local inference engine for Apple silicon, built around the model"
          homepage "https://github.com/incoai/splash"
          url "\(release.archiveURL)"
          version "\(release.version)"
          sha256 "\(checksum)"
          license "Apache-2.0"

          depends_on arch: :arm64
          depends_on macos: :tahoe
          depends_on SplashMacOSRequirement

          def install
            libexec.install Dir["*"]
            (bin/"splash").write <<~SH
              #!/bin/sh
              export PYTHONDONTWRITEBYTECODE=1
              exec "#{opt_libexec}/python/bin/python3" -u "#{opt_libexec}/install/launcher.py" "$@"
            SH
            chmod 0755, bin/"splash"
            zsh_completion.install_symlink libexec/"install/completions/_splash"
            bash_completion.install_symlink libexec/"install/completions/splash.bash" => "splash"
            fish_completion.install_symlink libexec/"install/completions/splash.fish"
          end

          test do
            assert_match version.to_s, shell_output("#{bin}/splash --version")
            assert_match "serve", shell_output("#{bin}/splash --help")
          end
        end
        """

        let formulaURL = formulaDirectory.appendingPathComponent("splash@\(release.version).rb")
        do {
            try Data(formula.utf8).write(to: formulaURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func linkedSplashFormula(using brew: String) -> String? {
        let prefix = runCommand(brew, ["--prefix"])
        guard prefix.status == 0 else { return nil }
        let executable = prefix.output + "/bin/splash"
        let link = runCommand("/usr/bin/readlink", [executable])
        guard link.status == 0 else { return nil }
        let components = link.output.split(separator: "/").map(String.init)
        guard let cellarIndex = components.firstIndex(of: "Cellar"), components.indices.contains(cellarIndex + 1) else { return nil }
        let formula = components[cellarIndex + 1]
        if formula == "splash" { return "incoai/tap/splash" }
        if formula.hasPrefix("splash@") { return "splashbar/splash-versions/\(formula)" }
        return nil
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
