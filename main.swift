import Cocoa

struct SplashBarSettings {
    /// Sentinel for the Splash installation found on the user's PATH (for
    /// example a Homebrew install). Any other value is a version that SplashBar
    /// downloads itself into `~/.splashbar/splash-versions/<version>`.
    static let globalVersion = "global"
    static let defaultLaunchdLabel = "local.llm.splash"
    static let defaultServerURL = URL(string: "http://127.0.0.1:8080")!
    static let defaultLogPath = NSHomeDirectory() + "/Library/Logs/Splash/splash.log"
    static let defaultRefreshInterval: TimeInterval = 5
    static let defaultRequestTimeout: TimeInterval = 2
    static let defaultIdleThresholdGB = 3.0
    static let defaultModelID = ""
    static let defaultMaxContext = ContextSize.auto

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
        static let maxContext = "maxContext"
        static let selectedVersion = "selectedVersion"
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
    var maxContext: ContextSize
    var selectedVersion: String

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
        maxContext = ContextSize(rawValue: defaults.string(forKey: Key.maxContext) ?? "") ?? Self.defaultMaxContext
        selectedVersion = defaults.string(forKey: Key.selectedVersion) ?? Self.globalVersion
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
        defaults.set(maxContext.rawValue, forKey: Key.maxContext)
        defaults.set(selectedVersion, forKey: Key.selectedVersion)
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
    /// Archive size in bytes, from the GitHub API. Zero when unknown.
    var size: Int = 0
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

/// The Splash executable visible on the user's PATH (for example the
/// Homebrew install). SplashBar only reads this location, never writes to it.
func globalSplashExecutablePath() -> String? {
    executablePath("splash", candidates: ["/opt/homebrew/bin/splash", "/usr/local/bin/splash"])
}

/// Root of the versions SplashBar manages itself, nvm-style.
func splashVersionsDirectory() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".splashbar", isDirectory: true)
        .appendingPathComponent("splash-versions", isDirectory: true)
}

/// The `splash` executable of a version SplashBar downloaded itself.
func localSplashExecutablePath(forVersion version: String) -> String? {
    guard version.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil else { return nil }
    let path = splashVersionsDirectory()
        .appendingPathComponent(version, isDirectory: true)
        .appendingPathComponent("splash")
        .path
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}

/// The executable SplashBar launches for the current selection: the user's
/// global install for `global`, otherwise the locally managed version.
func selectedSplashExecutablePath(selectedVersion: String) -> String? {
    if selectedVersion == SplashBarSettings.globalVersion {
        return globalSplashExecutablePath()
    }
    return localSplashExecutablePath(forVersion: selectedVersion)
}

/// Marker files every extracted release must contain.
private let splashVersionMarkers = ["install/launcher.py", "python/bin/python3", "release.json"]

/// Whether a version directory holds the files a usable Splash needs.
func versionMarkersPresent(in directory: URL) -> Bool {
    for marker in splashVersionMarkers {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(marker).path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else { return false }
    }
    return true
}

/// Whether the markers are present in `~/.splashbar/splash-versions/<version>`.
func localVersionIsComplete(_ version: String) -> Bool {
    let directory = splashVersionsDirectory().appendingPathComponent(version, isDirectory: true)
    return versionMarkersPresent(in: directory)
}

/// The release archives ship no `splash` executable; Homebrew generates one
/// as a wrapper around the bundled Python interpreter. We do the same so the
/// extracted directory is self-contained and works from any working directory.
func writeSplashVersionWrapper(in versionDirectory: URL) -> Bool {
    let wrapper = versionDirectory.appendingPathComponent("splash")
    let script = """
    #!/bin/sh
    DIR="$(cd "$(dirname "$0")" && pwd)"
    export PYTHONDONTWRITEBYTECODE=1
    exec "$DIR/python/bin/python3" -u "$DIR/install/launcher.py" "$@"
    """
    do {
        try Data(script.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return true
    } catch {
        return false
    }
}

func formatBytes(_ bytes: Int) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
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
            guard let archiveAsset = assets.first(where: { $0["name"] as? String == archiveName }),
                  let archive = archiveAsset["browser_download_url"] as? String,
                  let checksum = assets.first(where: { $0["name"] as? String == archiveName + ".sha256" })?["browser_download_url"] as? String,
                  archive.hasPrefix("https://github.com/incoai/splash/releases/download/"),
                  checksum.hasPrefix("https://github.com/incoai/splash/releases/download/") else { continue }
            releases.append(SplashRelease(
                version: version,
                archiveURL: archive,
                checksumURL: checksum,
                size: archiveAsset["size"] as? Int ?? 0
            ))
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

func splashVersionString(of executable: String?) -> String {
    guard let executable else { return tr("model.notinstalled") }
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

/// Reads `--max-context` from a LaunchAgent argument list (accepts both
/// `--max-context 16K` and `--max-context=16K`). Returns nil when the flag
/// is absent; that is equivalent to `.auto`.
func contextSize(in arguments: [String]) -> ContextSize? {
    var text: String?
    if let index = arguments.firstIndex(of: "--max-context"), arguments.indices.contains(index + 1) {
        text = arguments[index + 1]
    } else if let joined = arguments.first(where: { $0.hasPrefix("--max-context=") }) {
        text = joined.components(separatedBy: "=").dropFirst().joined(separator: "=")
    }
    guard let text = text, !text.isEmpty else { return nil }
    return ContextSize(rawValue: text.trimmingCharacters(in: .whitespaces).uppercased())
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

/// Context window limits for `splash serve --max-context`. Splash parses the
/// value case-insensitively (K = 1024 tokens, up to 256K); "auto" is the
/// model's native window when memory holds it.
enum ContextSize: String, CaseIterable {
    case auto = "AUTO"
    case c_16k = "16K"
    case c_32k = "32K"
    case c_64k = "64K"
    case c_128k = "128K"
    case c_192k = "192K"
    case c_256k = "256K"

    /// Title for the settings UI. The numeric sizes are the same in every
    /// language; only "auto" is localized.
    var displayName: String {
        if self == .auto { return tr("context.auto") }
        return rawValue
    }
}

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
    var versionProgressBar: NSProgressIndicator?
    private let versionDownloadLock = NSLock()
    private var versionDownloadActive = false
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
        if let arguments = readAgentPlist(at: settings.agentPlistPath)?["ProgramArguments"] as? [String] {
            if let configuredModel = modelID(in: arguments), configuredModel != settings.modelID {
                settings.modelID = configuredModel
                settings.save()
            }
            if let configuredContext = contextSize(in: arguments), configuredContext != settings.maxContext {
                settings.maxContext = configuredContext
                settings.save()
            }
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
        versionItem.isEnabled = !isUpdatingSplash
    }

    /// `splash --version` of the executable the current selection uses.
    func splashVersion() -> String {
        splashVersionString(of: selectedSplashExecutablePath(selectedVersion: settings.selectedVersion))
    }

    /// Short version string of the install found on the user's PATH, or the
    /// "not installed" label. Used for the "Global" entry of the version menu.
    func globalVersionString() -> String {
        guard let executable = globalSplashExecutablePath() else { return tr("model.notinstalled") }
        let result = runCommand(executable, ["--version"])
        guard result.status == 0 else { return tr("model.versionunknown") }
        return result.output.replacingOccurrences(of: "Splash ", with: "")
    }

    func refreshSplashVersion() {
        DispatchQueue.global(qos: .utility).async {
            let version = self.splashVersion()
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
        let urlField = NSTextField(string: settings.serverURL.absoluteString)
        let agentLabelField = NSTextField(string: settings.launchdLabel)
        let plistField = NSTextField(string: settings.agentPlistPath)
        let logField = NSTextField(string: settings.logPath)
        let refreshField = NSTextField(string: String(settings.refreshInterval))
        let timeoutField = NSTextField(string: String(settings.requestTimeout))
        let idleField = NSTextField(string: String(settings.idleThresholdGB))
        let contextField = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 0, height: 0), pullsDown: false)
        contextField.addItems(withTitles: ContextSize.allCases.map { $0.displayName })
        contextField.selectItem(withTitle: settings.maxContext.displayName)
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

        let fields: [(String, NSView)] = [
            (tr("settings.field.url"), urlField),
            (tr("settings.field.compatible", currentSplashVersion), compatibleModelField),
            (tr("settings.field.other"), otherModelField),
            (tr("settings.field.custom"), customModelField),
            (tr("settings.field.context"), contextField),
            (tr("settings.field.agent"), agentLabelField),
            (tr("settings.field.plist"), plistField),
            (tr("settings.field.log"), logField),
            (tr("settings.field.refresh"), refreshField),
            (tr("settings.field.timeout"), timeoutField),
            (tr("settings.field.idle"), idleField),
            (tr("settings.field.addpath"), additionalPathField)
        ]

        let form = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: CGFloat(fields.count) * 38))
        for (index, entry) in fields.enumerated() {
            let (title, field) = entry
            let y = CGFloat(fields.count - index - 1) * 38 + 6
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y, width: 230, height: 24)
            field.frame = NSRect(x: 237, y: y, width: index == fields.count - 1 ? 385 : 475, height: 24)
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

        let serverText = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedModel = [compatibleModelField, otherModelField]
            .map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            ?? customModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedContext = ContextSize.allCases
            .first { $0.displayName == (contextField.titleOfSelectedItem ?? "") } ?? .auto
        let additionalModelsPath = additionalPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverURL = validatedServerURL(serverText),
              requestedModel.isEmpty || validatedModelID(requestedModel),
              agentLabelField.stringValue.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil,
              !plistField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !logField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let refreshInterval = Double(refreshField.stringValue), refreshInterval.isFinite,
              refreshInterval >= 1, refreshInterval <= 3600,
              let requestTimeout = Double(timeoutField.stringValue), requestTimeout.isFinite,
              requestTimeout > 0, requestTimeout <= 60,
              let idleThresholdGB = Double(idleField.stringValue), idleThresholdGB.isFinite,
              idleThresholdGB > 0, idleThresholdGB <= 1024 else {
            showSettingsError()
            return
        }

        var updated = settings
        let oldDefaultPlist = NSHomeDirectory() + "/Library/LaunchAgents/\(settings.launchdLabel).plist"
        updated.launchdLabel = agentLabelField.stringValue
        updated.agentPlistPath = plistField.stringValue
        if updated.agentPlistPath == oldDefaultPlist {
            updated.agentPlistPath = NSHomeDirectory() + "/Library/LaunchAgents/\(updated.launchdLabel).plist"
        }
        updated.serverURL = serverURL
        updated.logPath = logField.stringValue
        updated.refreshInterval = refreshInterval
        updated.requestTimeout = requestTimeout
        updated.idleThresholdGB = idleThresholdGB
        updated.additionalModelsPath = additionalModelsPath
        updated.maxContext = requestedContext

        let agentArguments = readAgentPlist(at: updated.agentPlistPath)?["ProgramArguments"] as? [String] ?? []
        let currentAgentModel = modelID(in: agentArguments)
        let modelChanged = !requestedModel.isEmpty && requestedModel != currentAgentModel
        let currentAgentContext = contextSize(in: agentArguments) ?? .auto
        let contextChanged = requestedContext != currentAgentContext

        if modelChanged || contextChanged {
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
                restartAlert.addButton(withTitle: tr("settings.cancel"))
                guard runClosableAlert(restartAlert) == .alertFirstButtonReturn else { return }
            }

            if let error = applyServeArguments(
                requestedModel,
                context: requestedContext,
                settings: updated,
                previousSettings: settings,
                restartLoadedService: serviceLoaded
            ) {
                showSettingsError(error)
                return
            }
            if modelChanged {
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

    func applyServeArguments(
        _ selectedModel: String,
        context: ContextSize,
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
            guard let splashPath = selectedSplashExecutablePath(selectedVersion: updatedSettings.selectedVersion) else {
                return tr("validate.noagent")
            }
            // splash serve requires --model; a newly created agent without
            // one could never start, so no context flag alone is not enough.
            guard !selectedModel.isEmpty else {
                return tr("validate.modelrequired")
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

        // A cleared model field leaves any existing --model argument untouched.
        if !selectedModel.isEmpty {
            if let index = arguments.firstIndex(of: "--model"), arguments.indices.contains(index + 1) {
                arguments[index + 1] = selectedModel
            } else if let index = arguments.firstIndex(where: { $0.hasPrefix("--model=") }) {
                arguments[index] = "--model=\(selectedModel)"
            } else {
                arguments += ["--model", selectedModel]
            }
        }

        // "auto" means "let Splash decide", so the flag is left out entirely.
        if context == .auto {
            if let index = arguments.firstIndex(of: "--max-context"), arguments.indices.contains(index + 1) {
                arguments.removeSubrange(index...index + 1)
            } else if let index = arguments.firstIndex(where: { $0.hasPrefix("--max-context=") }) {
                arguments.remove(at: index)
            }
        } else {
            if let index = arguments.firstIndex(of: "--max-context"), arguments.indices.contains(index + 1) {
                arguments[index + 1] = context.rawValue
            } else if let index = arguments.firstIndex(where: { $0.hasPrefix("--max-context=") }) {
                arguments[index] = "--max-context=\(context.rawValue)"
            } else {
                arguments += ["--max-context", context.rawValue]
            }
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

                let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28), pullsDown: false)
                let globalTitle = tr("version.global.title", self.globalVersionString())
                selector.addItems(withTitles: [globalTitle] + releases.map(\.version))

                // Preselect the current selection; a selection that is no
                // longer offered (or a missing global install) falls back to Global.
                let currentSelection = self.settings.selectedVersion
                if currentSelection == SplashBarSettings.globalVersion {
                    selector.selectItem(at: 0)
                } else if let index = releases.firstIndex(where: { $0.version == currentSelection }) {
                    selector.selectItem(at: index + 1)
                } else {
                    selector.selectItem(at: 0)
                }

                let alert = NSAlert()
                alert.messageText = tr("version.pick.title")
                alert.informativeText = tr("version.pick.detail", self.splashVersion())
                alert.accessoryView = selector
                alert.addButton(withTitle: tr("version.switch"))
                alert.addButton(withTitle: tr("settings.cancel"))
                guard self.runClosableAlert(alert) == .alertFirstButtonReturn else {
                    self.finishVersionChange()
                    return
                }
                let selectedTitle = selector.titleOfSelectedItem ?? globalTitle
                let version = selectedTitle == globalTitle ? SplashBarSettings.globalVersion : selectedTitle
                self.switchToSplashVersion(version, releases: releases)
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

    /// Switches the Splash version SplashBar uses. `version` is either
    /// `SplashBarSettings.globalVersion` (the Splash install found on the
    /// user's PATH, e.g. via Homebrew) or a concrete release version, which
    /// SplashBar downloads itself into `~/.splashbar/splash-versions/<version>`
    /// and launches from there. The user's PATH is never modified.
    func switchToSplashVersion(_ version: String, releases: [SplashRelease]) {
        let isGlobal = version == SplashBarSettings.globalVersion
        let logURL = versionChangeDiagnostics.begin(version: version)
        versionChangeDiagnostics.record("Selected Splash version: \(version)")
        let initialText = isGlobal
            ? tr("version.activating", globalVersionString())
            : tr("version.installing", version)
        showVersionProgress(version: version, initialText: initialText)

        DispatchQueue.global(qos: .userInitiated).async {
            let serviceTarget = self.target
            let wasLoaded = self.isLoaded()
            let previousVersion = self.splashVersion()
            var errorText: String?
            var restartText: String?
            var agentChanged = false

            // 1. Release versions are used from ~/.splashbar/splash-versions;
            // download the missing pieces first. The wrapper is a generated
            // file, so it is (re)created in any case.
            if !isGlobal, errorText == nil {
                let versionDirectory = splashVersionsDirectory()
                    .appendingPathComponent(version, isDirectory: true)
                if !localVersionIsComplete(version) {
                    if let error = self.ensureLocalVersion(version, releases: releases) {
                        errorText = error
                    }
                }
                if errorText == nil {
                    _ = writeSplashVersionWrapper(in: versionDirectory)
                }
            }

            // 2. Resolve the executable the selection points at.
            let executablePath = selectedSplashExecutablePath(selectedVersion: version)
            if errorText == nil, executablePath == nil {
                errorText = isGlobal
                    ? tr("version.error.notfound")
                    : tr("version.error.wrapper", version)
            }
            guard errorText == nil, let executablePath else {
                let briefError = tr("version.error.install")
                versionChangeDiagnostics.record("ERROR: \(briefError)")
                versionChangeDiagnostics.record("Application stack trace:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
                versionChangeDiagnostics.end()
                DispatchQueue.main.async {
                    self.finishVersionChange()
                    self.completeVersionProgress(error: briefError, logURL: logURL)
                }
                return
            }

            // 3. Persist the selection.
            self.showVersionPhase(tr("version.activating", version), spinner: true)
            var updated = self.settings
            updated.selectedVersion = version
            updated.save()
            self.settings = updated

            // 4. The executable path in the LaunchAgent definition changes,
            // so a loaded service must be unloaded and re-bootstrapped.
            let currentAgentPath = readAgentPlist(at: self.settings.agentPlistPath)?["ProgramArguments"] as? [String]
            if currentAgentPath?.first != executablePath {
                agentChanged = true
                if wasLoaded {
                    let stopped = runCommand("/bin/launchctl", ["kill", "SIGTERM", serviceTarget])
                    if stopped.status != 0 || !self.waitForServiceToStop(serviceTarget) {
                        errorText = tr("version.error.stopstuck", stopped.output)
                    }
                    if errorText == nil {
                        let unloaded = runCommand("/bin/launchctl", ["bootout", serviceTarget])
                        if unloaded.status != 0 {
                            errorText = tr("version.error.unloadfailed", unloaded.output)
                        }
                    }
                }
                if errorText == nil, let pointError = self.pointAgentAt(executablePath) {
                    errorText = pointError
                }
                if errorText == nil, wasLoaded {
                    let started = runCommand("/bin/launchctl", ["bootstrap", "gui/\(self.uid)", expandedPath(self.settings.agentPlistPath)])
                    if started.status != 0 {
                        restartText = tr("version.error.notstarted", started.output)
                    }
                }
            } else {
                versionChangeDiagnostics.record("No change: the LaunchAgent already points at \(executablePath).")
            }

            // 5. Report.
            let installedVersion = self.splashVersion()
            versionChangeDiagnostics.record("Previous version: \(previousVersion)")
            versionChangeDiagnostics.record("Version after the switch: \(installedVersion)")
            if let errorText { versionChangeDiagnostics.record("ERROR: \(errorText)") }
            if let restartText { versionChangeDiagnostics.record("ERROR: \(restartText)") }
            if errorText != nil || restartText != nil {
                versionChangeDiagnostics.record("Application stack trace:\n\(Thread.callStackSymbols.joined(separator: "\n"))")
            }
            versionChangeDiagnostics.end()

            let failureText = [errorText, restartText].compactMap { $0 }.joined(separator: "\n\n")
            let displayName = installedVersion.replacingOccurrences(of: "Splash ", with: "")
            let successMessage = !agentChanged && failureText.isEmpty
                ? tr("version.alreadyactive", displayName)
                : tr("version.success", installedVersion)
            let briefError = restartText != nil
                ? tr("version.error.restart")
                : tr("version.error.install")

            DispatchQueue.main.async {
                self.finishVersionChange()
                self.versionLine.title = tr("status.version", installedVersion)
                self.refresh()
                if failureText.isEmpty {
                    self.completeVersionProgress(message: successMessage, logURL: logURL)
                } else {
                    self.completeVersionProgress(error: briefError, logURL: logURL)
                }
            }
        }
    }

    func finishVersionChange() {
        isUpdatingSplash = false
        versionItem.isEnabled = true
        refresh()
    }

    func showVersionProgress(version: String, initialText: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("window.title")
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 230))
        let text = NSTextField(wrappingLabelWithString: initialText)
        text.frame = NSRect(x: 24, y: 76, width: 492, height: 130)
        text.font = .systemFont(ofSize: 14)
        content.addSubview(text)

        let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 44, width: 400, height: 20))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true
        content.addSubview(bar)

        let spinner = NSProgressIndicator(frame: NSRect(x: 436, y: 38, width: 20, height: 20))
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
        versionProgressBar = bar
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
        versionProgressBar?.stopAnimation(nil)
        versionProgressBar?.isHidden = true
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
        versionProgressBar = nil
        versionProgressSpinner = nil
        versionLogButton = nil
        versionCloseButton = nil
        versionProgressLogURL = nil
    }

    /// Updates the progress window text and shows the spinner (indeterminate
    /// phase). Must be called on the main thread.
    func showVersionPhase(_ text: String, spinner: Bool) {
        versionProgressText?.stringValue = text
        versionProgressSpinner?.isHidden = !spinner
        versionProgressBar?.isHidden = spinner
    }

    /// Updates the download progress bar. Must be called on the main thread.
    func showVersionDownloadProgress(_ version: String, downloaded: Int, total: Int) {
        versionProgressSpinner?.isHidden = true
        versionProgressBar?.isHidden = false
        if total > 0 {
            versionProgressBar?.isIndeterminate = false
            versionProgressBar?.minValue = 0
            versionProgressBar?.maxValue = Double(total)
            versionProgressBar?.doubleValue = Double(min(downloaded, total))
            versionProgressText?.stringValue = tr(
                "version.downloading", version, formatBytes(downloaded), formatBytes(total)
            )
        } else {
            versionProgressBar?.isIndeterminate = true
        }
    }

    /// Sets whether the download progress poller runs.
    func setVersionDownloadActive(_ active: Bool) {
        versionDownloadLock.lock()
        versionDownloadActive = active
        versionDownloadLock.unlock()
    }

    func isVersionDownloadActive() -> Bool {
        versionDownloadLock.lock()
        defer { versionDownloadLock.unlock() }
        return versionDownloadActive
    }

    /// Downloads, verifies and extracts a release into
    /// `~/.splashbar/splash-versions/<version>`, mirroring the way Homebrew
    /// keeps versioned installs side by side. Shows a progress bar while the
    /// archive is downloaded. Returns a localized error message on failure.
    func ensureLocalVersion(_ version: String, releases: [SplashRelease]) -> String? {
        guard let release = releases.first(where: { $0.version == version }) else {
            return tr("version.error.releasegone")
        }

        let fileManager = FileManager.default
        let versionsRoot = splashVersionsDirectory()
        let finalDirectory = versionsRoot.appendingPathComponent(version, isDirectory: true)
        do {
            try fileManager.createDirectory(at: versionsRoot, withIntermediateDirectories: true)
        } catch {
            return tr("version.error.download", version, error.localizedDescription)
        }

        let archiveURL = fileManager.temporaryDirectory
            .appendingPathComponent("splashbar-\(version)-\(UUID().uuidString).tar.gz")
        defer { try? fileManager.removeItem(at: archiveURL) }

        // 1. Download, with a progress bar driven by a polling thread.
        setVersionDownloadActive(true)
        let poller = Thread { [weak self] in
            while let self, self.isVersionDownloadActive() {
                let downloaded = (try? fileManager.attributesOfItem(atPath: archiveURL.path)[.size] as? Int) ?? 0
                let total = release.size
                let versionText = version
                DispatchQueue.main.async {
                    self.showVersionDownloadProgress(versionText, downloaded: downloaded, total: total)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        poller.start()

        let download = runCommand("/usr/bin/curl", [
            "--fail", "--silent", "--show-error", "--location",
            "--output", archiveURL.path,
            release.archiveURL
        ])
        setVersionDownloadActive(false)
        guard download.status == 0 else {
            return tr("version.error.download", version, download.output)
        }

        // 2. Verify the downloaded archive against the published SHA-256.
        showVersionPhase(tr("version.verifying", version), spinner: true)
        guard let expected = publishedChecksum(for: release) else {
            return tr("version.error.checksum", version)
        }
        guard let actual = sha256OfFile(archiveURL), actual == expected else {
            return tr("version.error.checksum", version)
        }

        // 3. Extract into a staging directory, then swap it into place so the
        // version directory never holds a half-extracted install.
        showVersionPhase(tr("version.extracting", version), spinner: true)
        let staging = versionsRoot
            .appendingPathComponent(".\(version)-staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return tr("version.error.extract", version, error.localizedDescription)
        }

        let listing = runCommand("/usr/bin/tar", ["-tzf", archiveURL.path])
        guard listing.status == 0 else {
            try? fileManager.removeItem(at: staging)
            return tr("version.error.extract", version, listing.output)
        }
        let topLevel = Set(
            listing.output.split(separator: "\n")
                .compactMap { $0.split(separator: "/").first }
                .map(String.init)
        )
        guard topLevel.count == 1 else {
            try? fileManager.removeItem(at: staging)
            return tr("version.error.extract", version, tr("version.error.unexpectedlayout"))
        }

        let extract = runCommand("/usr/bin/tar", ["-xzf", archiveURL.path, "-C", staging.path, "--strip-components=1"])
        guard extract.status == 0, versionMarkersPresent(in: staging) else {
            try? fileManager.removeItem(at: staging)
            return tr("version.error.extract", version, extract.output)
        }
        guard writeSplashVersionWrapper(in: staging) else {
            try? fileManager.removeItem(at: staging)
            return tr("version.error.wrapper", version)
        }

        if fileManager.fileExists(atPath: finalDirectory.path) {
            do {
                try fileManager.removeItem(at: finalDirectory)
            } catch {
                try? fileManager.removeItem(at: staging)
                return tr("version.error.extract", version, error.localizedDescription)
            }
        }
        do {
            try fileManager.moveItem(at: staging, to: finalDirectory)
        } catch {
            try? fileManager.removeItem(at: staging)
            return tr("version.error.extract", version, error.localizedDescription)
        }
        return nil
    }

    /// Rewrites the first entry of the LaunchAgent's ProgramArguments to the
    /// given executable path, preserving all other plist keys. Returns nil
    /// when the agent points at the new executable or no agent is configured,
    /// or a localized error message.
    func pointAgentAt(_ executablePath: String) -> String? {
        let plistURL = URL(fileURLWithPath: expandedPath(settings.agentPlistPath))
        guard let data = try? Data(contentsOf: plistURL),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              var plist = value as? [String: Any] else {
            return nil  // No LaunchAgent configured; the selection applies once one is.
        }
        var arguments = plist["ProgramArguments"] as? [String] ?? []
        guard !arguments.isEmpty,
              URL(fileURLWithPath: arguments[0]).lastPathComponent == "splash" else {
            return tr("validate.badplist")
        }
        arguments[0] = executablePath
        plist["ProgramArguments"] = arguments
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try out.write(to: plistURL, options: .atomic)
            return nil
        } catch {
            return tr("validate.savfailed", error.localizedDescription)
        }
    }

    /// Fetches the release's `.sha256` file and returns the published digest.
    func publishedChecksum(for release: SplashRelease) -> String? {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("splashbar-\(UUID().uuidString).sha256")
        let download = runCommand("/usr/bin/curl", [
            "--fail", "--silent", "--show-error", "--location",
            "--output", file.path,
            release.checksumURL
        ])
        guard download.status == 0,
              let contents = try? String(contentsOf: file, encoding: .utf8) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        try? FileManager.default.removeItem(at: file)
        guard let pattern = try? NSRegularExpression(pattern: #"\b([a-fA-F0-9]{64})\b"#),
              let match = pattern.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
              let range = Range(match.range(at: 1), in: contents) else { return nil }
        return String(contents[range]).lowercased()
    }

    func sha256OfFile(_ url: URL) -> String? {
        let result = runCommand("/usr/bin/shasum", ["-a", "256", url.path])
        guard result.status == 0 else { return nil }
        return result.output.split(separator: " ").first.map { $0.lowercased() }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
