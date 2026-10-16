import Cocoa

struct SplashBarSettings {
    /// Read from Info.plist at runtime (build.sh sets CFBundleShortVersionString);
    /// the fallback covers running the binary outside of a bundle (e.g. from Xcode).
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        ?? "0.1.1"
    /// Sentinel for the Splash installation found on the user's PATH (for
    /// example a Homebrew install). Any other value is a version that SplashBar
    /// downloads itself into `~/.splashbar/splash-versions/<version>`.
    static let globalVersion = "global"
    static let defaultLaunchdLabel = "local.llm.splash"
    /// The LaunchAgent that makes SplashBar *itself* start at login (installed
    /// by build.sh). Managed by the "Launch at login" setting; its contents are
    /// fixed, so it can be removed and recreated freely.
    static let appAgentLabel = "local.splashbar"
    static var appAgentPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(appAgentLabel).plist"
    }
    static let defaultServerURL = URL(string: "http://127.0.0.1:8080")!
    static let defaultLogPath = NSHomeDirectory() + "/Library/Logs/Splash/splash.log"
    static let defaultRefreshInterval: TimeInterval = 5
    static let defaultRequestTimeout: TimeInterval = 2
    static let defaultIdleThresholdGB = 3.0
    static let defaultModelID = ""
    static let defaultMaxContext = ContextSize.auto
    static let defaultAPIKey = ""
    static let defaultAllowedHost = ""
    /// Where the Hugging Face hub cache lives. Splash reads this directory from
    /// the HF_HUB_CACHE environment variable (via huggingface_hub); the default
    /// is the standard location. Changing it redirects all future model
    /// downloads without touching Splash.
    static let defaultModelCacheDirectory = NSHomeDirectory() + "/.cache/huggingface/hub"

    private enum Key {
        static let versionLabel = "versionLabel"
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
        static let apiKey = "apiKey"
        static let allowedHost = "allowedHost"
        static let modelCacheDirectory = "modelCacheDirectory"
        static let selectedVersion = "selectedVersion"
        static let launchAtLogin = "launchAtLogin"
    }

    var versionLabel: String
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
    var apiKey: String
    var allowedHost: String
    var modelCacheDirectory: String
    var selectedVersion: String
    /// Whether SplashBar itself starts at login (its own LaunchAgent).
    var launchAtLogin: Bool

    init(defaults: UserDefaults = .standard) {
        versionLabel = Self.appVersion
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
        apiKey = defaults.string(forKey: Key.apiKey) ?? Self.defaultAPIKey
        allowedHost = defaults.string(forKey: Key.allowedHost) ?? Self.defaultAllowedHost
        modelCacheDirectory = defaults.string(forKey: Key.modelCacheDirectory) ?? Self.defaultModelCacheDirectory
        selectedVersion = defaults.string(forKey: Key.selectedVersion) ?? Self.globalVersion
        // First start (no stored value yet): follow what is actually on disk,
        // so the checkbox matches the current launch-at-login behavior.
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool
            ?? FileManager.default.fileExists(atPath: Self.appAgentPlistPath)
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(versionLabel, forKey: Key.versionLabel)
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
        defaults.set(apiKey, forKey: Key.apiKey)
        defaults.set(allowedHost, forKey: Key.allowedHost)
        defaults.set(modelCacheDirectory, forKey: Key.modelCacheDirectory)
        defaults.set(selectedVersion, forKey: Key.selectedVersion)
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
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

/// Runs `executable` with `arguments` and captures its combined output.
/// `isCancelled` is polled while the process runs; once it returns true the
/// process is terminated (SIGTERM, then SIGKILL if it lingers) and the
/// result carries the process's termination status.
func runCommand(
    _ executable: String,
    _ arguments: [String],
    isCancelled: @escaping () -> Bool = { false }
) -> CommandResult {
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
        while process.isRunning {
            if isCancelled() {
                process.terminate()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
            if process.isRunning {
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
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

/// The versions SplashBar has downloaded into `~/.splashbar/splash-versions`,
/// newest first. Staging leftovers and other non-version entries are ignored.
func localSplashVersions() -> [String] {
    let directory = splashVersionsDirectory()
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var isDirectory: ObjCBool = false
    let versions = entries
        .filter {
            $0.lastPathComponent.range(of: #"^\d+(?:\.\d+){1,3}$"#, options: .regularExpression) != nil
                && FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        .map(\.lastPathComponent)
    return versions.sorted { lhs, rhs in
        guard let result = compareVersions(lhs, rhs), result != .orderedSame else { return lhs > rhs }
        return result == .orderedDescending
    }
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

/// The total size of a folder's regular files, for the backup progress bar.
/// Hidden files are included on purpose: the model cache keeps its references
/// in dot directories and all of them belong into a backup.
func folderSize(of url: URL) -> Int64 {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
    ) else { return 0 }
    var total: Int64 = 0
    while let item = enumerator.nextObject() as? URL {
        guard let values = try? item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { continue }
        total += Int64(values.fileSize ?? 0)
    }
    return total
}

// Localizes a key from the app's .lproj resources. The development language is
// German; if the user's system language has no translation file, AppKit falls
// back to it automatically (see CFBundleDevelopmentRegion in Info.plist).
// Missing keys resolve to the key itself, which keeps gaps visible.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    // Never hand the format string to Core Foundation: on macOS 27,
    // String(format:locale:arguments:) mangles String arguments (%s reads a
    // dangling C buffer, so it prints garbage or crashes with
    // EXC_BAD_ACCESS). The backup confirm dialog hit exactly that.
    return formatSwift(format, args)
}

/// Substitutes %s, %@, %d, %ld, %llu, %f, %lf and their N$ positional
/// forms, in pure Swift. The N$ form lets one value appear twice ("~26.5 GB
/// ... needs ~26.5 GB of free space") without duplicating the argument.
func formatSwift(_ format: String, _ args: [CVarArg]) -> String {
    var out = ""
    var seq = 0
    var i = format.startIndex
    while i < format.endIndex {
        let c = format[i]
        if c != "%" {
            out.append(c)
            i = format.index(after: i)
            continue
        }
        var j = format.index(after: i)
        var position: Int?
        if j < format.endIndex, format[j].isNumber {
            var digits = ""
            while j < format.endIndex, format[j].isNumber {
                digits.append(format[j])
                j = format.index(after: j)
            }
            if j < format.endIndex, format[j] == "$" {
                position = Int(digits)
                j = format.index(after: j)
            }
        }
        while j < format.endIndex, format[j].isNumber
                || (format[j] == "." && format.index(after: j) < format.endIndex) {
            j = format.index(after: j)
        }
        guard j < format.endIndex, "s@dflluXx".contains(format[j]) else {
            out.append("%")  // Not a directive (e.g. "100% of") — keep it.
            i = format.index(after: i)
            continue
        }
        let index = position.flatMap { $0 - 1 }
            .flatMap { $0 >= 0 && $0 < args.count ? $0 : nil }
            ?? (seq < args.count ? seq : nil)
        if position == nil { seq += 1 }
        if let index { out.append(renderArgument(args[index], format[j])) }
        i = format.index(after: j)
    }
    return out
}

private func renderArgument(_ arg: CVarArg, _ conversion: Character) -> String {
    if let s = arg as? String { return s }
    if String(conversion) == "f" || String(conversion) == "lf", let d = arg as? Double {
        return d.formatted()
    }
    return "\(arg)"
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

/// Reads a simple `--flag <value>` (or `--flag=<value>`) pair from a
/// LaunchAgent argument list. Returns nil when the flag is absent or its
/// value is empty.
func argumentValue(_ flag: String, in arguments: [String]) -> String? {
    var text: String?
    if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
        text = arguments[index + 1]
    } else if let joined = arguments.first(where: { $0.hasPrefix(flag + "=") }) {
        text = joined.components(separatedBy: "=").dropFirst().joined(separator: "=")
    }
    guard let text = text, !text.isEmpty else { return nil }
    return text
}

func modelID(in arguments: [String]) -> String? {
    argumentValue("--model", in: arguments)
}

/// Reads `--max-context` from a LaunchAgent argument list (accepts both
/// `--max-context 16K` and `--max-context=16K`). Returns nil when the flag
/// is absent; that is equivalent to `.auto`.
func contextSize(in arguments: [String]) -> ContextSize? {
    argumentValue("--max-context", in: arguments).flatMap {
        ContextSize(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased())
    }
}

/// Adds or updates a simple `--flag <value>` serve argument in a LaunchAgent
/// argument list (accepts both `--flag value` and `--flag=value`). An empty
/// value removes the flag so the argument is left out entirely.
func upsertServeArgument(_ flag: String, _ value: String, into arguments: inout [String]) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
            arguments.removeSubrange(index...index + 1)
        } else if let index = arguments.firstIndex(where: { $0.hasPrefix(flag + "=") }) {
            arguments.remove(at: index)
        }
        return
    }
    if let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
        arguments[index + 1] = trimmed
    } else if let index = arguments.firstIndex(where: { $0.hasPrefix(flag + "=") }) {
        arguments[index] = "\(flag)=\(trimmed)"
    } else {
        arguments += [flag, trimmed]
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
    let host = url.host() ?? "Server"
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
    let appVersionLine = NSMenuItem(title: "SplashBar v" + SplashBarSettings.appVersion, action: nil, keyEquivalent: "")
    let versionLine = NSMenuItem(title: tr("status.versionchecking"), action: nil, keyEquivalent: "")
    var startItem: NSMenuItem!
    var stopItem: NSMenuItem!
    var restartItem: NSMenuItem!
    var versionItem: NSMenuItem!
    var timer: Timer?
    var isUpdatingSplash = false
    var isQuitting = false
    var versionProgressWindow: NSWindow?
    var versionProgressText: NSTextField?
    var versionProgressSpinner: NSProgressIndicator?
    var versionProgressBar: NSProgressIndicator?
    private let versionDownloadLock = NSLock()
    private var versionDownloadActive = false
    private var versionDownloadCancelled = false
    private var versionDownloadVersionText = ""
    var versionLogButton: NSButton?
    var versionCancelButton: NSButton?
    var versionCloseButton: NSButton?
    var versionProgressLogURL: URL?
    var activeModalAlertWindow: NSWindow?
    var activeModalCloseResponse: NSApplication.ModalResponse = .alertSecondButtonReturn
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
            if let configuredAPIKey = argumentValue("--api-key", in: arguments), configuredAPIKey != settings.apiKey {
                settings.apiKey = configuredAPIKey
                settings.save()
            }
            if let configuredAllowedHost = argumentValue("--allowed-host", in: arguments), configuredAllowedHost != settings.allowedHost {
                settings.allowedHost = configuredAllowedHost
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
        menu.addItem(appVersionLine)
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
        _ = add(menu, tr("menu.backup"), #selector(backupModel))
        _ = add(menu, tr("menu.restore"), #selector(restoreModel))
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
        // While quitting, the dot stays orange ("killing the instance") no
        // matter what the state probe reports until the app is gone.
        guard !isQuitting else { return }
        // Reconcile the on-disk state with the stored launch-at-login
        // preference: build.sh or another tool may have created or changed
        // the files although the user turned the feature off.
        // - the app's own agent must not exist when the preference is off,
        // - the splash agent's RunAtLoad must match the preference, so the
        //   splash executable only starts on its own at login when the app
        //   starts too (and can supervise it). With the preference off and
        //   RunAtLoad true, launchd would launch the executable at login
        //   while this app — its only controller — is not running.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            if !self.settings.launchAtLogin {
                self.applyLaunchAtLogin(false)
            }
            self.syncAgentRunAtLogin(self.settings.launchAtLogin)
        }
        let currentSettings = settings
        let serviceTarget = target
        DispatchQueue.global(qos: .utility).async {
            let pid = sh("launchctl print \(shellQuote(serviceTarget)) 2>/dev/null | awk '$1==\"pid\" {print $3; exit}'")
            var state = ServerState.stopped
            var memoryGB: Double = 0
            var model = ""
            if !pid.isEmpty {
                // The server may be configured for a non-loopback host (e.g.
                // 0.0.0.0 with an API key), but the probe must always reach
                // loopback: keep the scheme and port of the configured URL,
                // force the host to 127.0.0.1.
                var healthComponents = URLComponents(url: currentSettings.serverURL, resolvingAgainstBaseURL: false)
                healthComponents?.host = "127.0.0.1"
                let healthURL = (healthComponents?.url ?? currentSettings.serverURL)
                    .appendingPathComponent("v1")
                    .appendingPathComponent("models")
                var probeArguments = ["-s", "-m", shellQuote(String(currentSettings.requestTimeout))]
                probeArguments += self.apiKeyHeaderArguments(currentSettings.apiKey)
                probeArguments += ["-o", "/dev/null", "-w", shellQuote("%{http_code}"), shellQuote(healthURL.absoluteString)]
                let code = sh("curl " + probeArguments.joined(separator: " "))
                let child = sh("pgrep -P \(shellQuote(pid)) | head -1")
                memoryGB = footprintGB(child.isEmpty ? pid : child)
                model = self.currentModel(
                    healthURL,
                    timeout: currentSettings.requestTimeout,
                    apiKey: currentSettings.apiKey
                )
                if code == "200" {
                    state = memoryGB < currentSettings.idleThresholdGB ? .idle : .running
                } else {
                    state = .loading
                }
            }
            DispatchQueue.main.async { self.apply(state, memoryGB, model) }
        }
    }

    /// curl arguments that add the `x-api-key` header for a configured key,
    /// so a server started with `--api-key` accepts the request. An empty key
    /// leaves the request unauthenticated.
    private func apiKeyHeaderArguments(_ apiKey: String) -> [String] {
        apiKey.isEmpty ? [] : ["-H", shellQuote("x-api-key: \(apiKey)")]
    }

    /// Liest das gerade geladene Modell vom Server (z. B. "mlx-community/Qwen3.8-27B-4bit")
    /// und hält die Menüzeile mit einer Kürzung auf 34 Zeichen schmal.
    /// Ein konfigurierter API-Key wird als `x-api-key`-Header mitgegeben, damit
    /// ein mit `--api-key` gestarteter Server die Anfrage beantwortet.
    func currentModel(_ url: URL, timeout: TimeInterval, apiKey: String = "") -> String {
        var arguments = ["-s", "-m", shellQuote(String(timeout))]
        arguments += apiKeyHeaderArguments(apiKey)
        arguments.append(shellQuote(url.absoluteString))
        let raw = sh("curl " + arguments.joined(separator: " "))
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

    /// The colored dot appended to the menu-bar icon.
    func setDot(_ color: NSColor) {
        item.button?.attributedTitle = NSAttributedString(
            string: " ●",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 9)]
        )
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
        setDot(color)
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
            // Bootstrap the agent when it is not loaded, then kick the job
            // when no process is running: with a RunAtLoad=false agent the
            // bootstrap alone would leave the job loaded but inert, so the
            // explicit kickstart is what starts the executable in every
            // configuration.
            if !self.isLoaded() {
                sh("launchctl bootstrap gui/\(self.uid) \(shellQuote(expandedPath(self.settings.agentPlistPath)))")
            }
            if self.servicePID(self.target) == nil {
                sh("launchctl kickstart \(shellQuote(self.target))")
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
                if self.servicePID(self.target) == nil {
                    sh("launchctl kickstart \(shellQuote(self.target))")
                }
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
        let modelCacheField = NSTextField(string: settings.modelCacheDirectory)
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
        let apiKeyField = NSTextField(string: settings.apiKey)
        let allowedHostField = NSTextField(string: settings.allowedHost)
        let launchAtLoginField = NSButton(checkboxWithTitle: tr("settings.field.launchatlogin"), target: nil, action: nil)
        launchAtLoginField.state = settings.launchAtLogin ? .on : .off
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
            ("", launchAtLoginField),
            (tr("settings.field.url"), urlField),
            (tr("settings.field.compatible", currentSplashVersion), compatibleModelField),
            (tr("settings.field.other"), otherModelField),
            (tr("settings.field.custom"), customModelField),
            (tr("settings.field.context"), contextField),
            (tr("settings.field.apikey"), apiKeyField),
            (tr("settings.field.allowedhost"), allowedHostField),
            (tr("settings.field.agent"), agentLabelField),
            (tr("settings.field.plist"), plistField),
            (tr("settings.field.log"), logField),
            (tr("settings.field.refresh"), refreshField),
            (tr("settings.field.timeout"), timeoutField),
            (tr("settings.field.idle"), idleField),
            (tr("settings.field.addpath"), additionalPathField),
            (tr("settings.field.modelcache"), modelCacheField)
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
        let requestedAPIKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedAllowedHost = allowedHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionalModelsPath = additionalPathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedLaunchAtLogin = launchAtLoginField.state == .on
        let modelCacheDirectory = modelCacheField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let currentLaunchAtLogin = settings.launchAtLogin
        updated.launchAtLogin = requestedLaunchAtLogin
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
        updated.apiKey = requestedAPIKey
        updated.allowedHost = requestedAllowedHost
        updated.modelCacheDirectory = modelCacheDirectory.isEmpty
            ? SplashBarSettings.defaultModelCacheDirectory
            : modelCacheDirectory

        // The URL currently stored in the settings. When it differs from the
        // validated one, the LaunchAgent's --port argument is rewritten and a
        // running server is restarted so the new address takes effect.
        let currentServerUrl = settings.serverURL
        let agentArguments = readAgentPlist(at: updated.agentPlistPath)?["ProgramArguments"] as? [String] ?? []
        let currentAgentModel = modelID(in: agentArguments)
        let serverUrlChanged = serverURL != currentServerUrl
        let modelChanged = !requestedModel.isEmpty && requestedModel != currentAgentModel
        let currentAgentContext = contextSize(in: agentArguments) ?? .auto
        let contextChanged = requestedContext != currentAgentContext
        let apiKeyChanged = requestedAPIKey != (argumentValue("--api-key", in: agentArguments) ?? "")
        let allowedHostChanged = requestedAllowedHost != (argumentValue("--allowed-host", in: agentArguments) ?? "")
        // The cache directory lives in the plist's EnvironmentVariables (HF_HUB_CACHE).
        let agentEnvironment = readAgentPlist(at: updated.agentPlistPath)?["EnvironmentVariables"] as? [String: Any] ?? [:]
        let modelCacheChanged = agentEnvironment["HF_HUB_CACHE"] as? String != expandedPath(updated.modelCacheDirectory)

        if serverUrlChanged || modelChanged || contextChanged || apiKeyChanged || allowedHostChanged || modelCacheChanged {
            guard isValidServerUrl(serverURL, apiKey: requestedAPIKey) else {
                showSettingsError(tr("settings.error.agent"))
                return
            }
            let oldTarget = "gui/\(uid)/\(settings.launchdLabel)"
            let serviceLoaded = !sh("launchctl print \(shellQuote(oldTarget)) >/dev/null 2>&1 && echo yes").isEmpty
            // A loaded service is restarted by default so the new LaunchAgent
            // arguments take effect immediately; "save and apply later" keeps
            // the instance running and defers them to the next start.
            var restartLoadedService = serviceLoaded
            if serviceLoaded {
                let restartAlert = NSAlert()
                restartAlert.messageText = tr("model.restart")
                restartAlert.informativeText = tr("model.restart.detail")
                restartAlert.addButton(withTitle: tr("model.restart.switch"))
                restartAlert.addButton(withTitle: tr("settings.applylater"))
                restartAlert.addButton(withTitle: tr("settings.cancel"))
                // The window's close button aborts the save like Cancel,
                // never like the middle "apply later" button.
                let response = runClosableAlert(restartAlert, closeAs: .alertThirdButtonReturn)
                if response == .alertSecondButtonReturn {
                    restartLoadedService = false
                } else if response != .alertFirstButtonReturn {
                    return
                }
            }

            if let error = applyServeArguments(
                requestedModel,
                context: requestedContext,
                settings: updated,
                previousSettings: settings,
                restartLoadedService: restartLoadedService
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
        // The login agent belongs to the app itself, not to the server, so the
        // toggle is applied directly: it takes effect at the next login and
        // needs no server restart. The splash agent's RunAtLoad follows the
        // same toggle, so the executable never starts at login on its own.
        if requestedLaunchAtLogin != currentLaunchAtLogin {
            applyLaunchAtLogin(requestedLaunchAtLogin)
            syncAgentRunAtLogin(requestedLaunchAtLogin)
        }
        refresh()
    }

    /// (Re)creates or removes the LaunchAgent that makes SplashBar itself
    /// start at login. The agent's contents are fixed (label, executable path,
    /// RunAtLoad), so removing it when the toggle is off loses no user state,
    /// and enabling simply writes the file back. launchd reads the file at the
    /// next login, which is when the change takes effect. The agent is
    /// therefore never bootstrapped from here: that would start a second
    /// SplashBar instance while this one is running. A loaded service is
    /// booted out when turning the feature off, unless its process is this
    /// very app instance — booting that out would terminate the app, so in
    /// that case only the file is removed. The splash agent's RunAtLoad is a
    /// separate concern handled by `syncAgentRunAtLogin`; callers that change
    /// the toggle should run both.
    func applyLaunchAtLogin(_ enabled: Bool) {
        let label = SplashBarSettings.appAgentLabel
        let serviceTarget = "gui/\(uid)/\(label)"
        let plistPath = SplashBarSettings.appAgentPlistPath
        let fileManager = FileManager.default
        let isLoaded = !sh("launchctl print \(shellQuote(serviceTarget)) >/dev/null 2>&1 && echo yes").isEmpty
        let serviceOwnsThisProcess = isLoaded && servicePID(serviceTarget) == String(getpid())

        if enabled {
            let agent: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.executableURL?.path
                    ?? "/Applications/SplashBar.app/Contents/MacOS/SplashBar"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive"
            ]
            do {
                let url = URL(fileURLWithPath: plistPath)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
            } catch {
                showSettingsError(tr("settings.error.launchatlogin", error.localizedDescription))
            }
            return
        }

        if isLoaded, !serviceOwnsThisProcess {
            _ = runCommand("/bin/launchctl", ["bootout", serviceTarget])
        }
        try? fileManager.removeItem(atPath: plistPath)
    }

    /// Keeps the splash agent's `RunAtLoad` key in sync with the launch at
    /// login preference, so the splash executable only starts on its own at
    /// login when the menubar app starts too (and can supervise the server).
    /// With the preference off, a `true` left behind by an older build or a
    /// hand edit would make launchd launch the executable at login while the
    /// app — its only controller — is not running. Only that one key is
    /// touched, and the file is rewritten only when it differs, so this is
    /// cheap enough to run on every refresh. A missing agent file (the server
    /// is started without one) is a no-op.
    func syncAgentRunAtLogin(_ enabled: Bool) {
        let plistURL = URL(fileURLWithPath: expandedPath(settings.agentPlistPath))
        guard let data = try? Data(contentsOf: plistURL),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              var plist = value as? [String: Any] else { return }
        // launchd starts a job at load time when RunAtLoad is absent, so an
        // absent key counts as true.
        let current = (plist["RunAtLoad"] as? Bool) ?? true
        guard current != enabled else { return }
        plist["RunAtLoad"] = enabled
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try out.write(to: plistURL, options: .atomic)
        } catch {
            // Best effort: the preference itself is stored either way, and
            // the next refresh retries the sync.
        }
    }

    func validatedModelID(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*(?::[A-Za-z0-9._-]+)?$"#, options: .regularExpression) != nil
            && !text.split(separator: "/").contains("..")
    }

    /// Validates the server URL for the LaunchAgent-based features.
    /// Loopback addresses are always allowed; 0.0.0.0 binds to every
    /// interface, so it is only accepted together with an API key — a
    /// keyless server must never be reachable from the whole network.
    func isValidServerUrl(_ url: URL, apiKey: String) -> Bool {
        var host = (url.host ?? "").lowercased()
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if ["localhost", "127.0.0.1", "::1"].contains(host) { return true }
        return host == "0.0.0.0" && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
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

        let host = String(updatedSettings.serverURL.host() ?? "127.0.0.1")
        if let index = arguments.firstIndex(of: "--host"), arguments.indices.contains(index + 1) {
            arguments[index + 1] = host
        } else if let index = arguments.firstIndex(where: { $0.hasPrefix("--host=") }) {
            arguments[index] = "--host=\(host)"
        } else {
            arguments += ["--host", host]
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

        // Optional serve arguments: written only when the user entered a
        // value, removed entirely when the field is empty.
        upsertServeArgument("--api-key", updatedSettings.apiKey, into: &arguments)
        upsertServeArgument("--allowed-host", updatedSettings.allowedHost, into: &arguments)

        plist["Label"] = updatedSettings.launchdLabel
        plist["ProgramArguments"] = arguments
        // The splash executable is owned by this app, so it must not be
        // launched by launchd at login unless the app starts too (and can
        // supervise the server): RunAtLoad mirrors the launch-at-login
        // preference instead of a fixed true.
        plist["RunAtLoad"] = updatedSettings.launchAtLogin
        plist["KeepAlive"] = false
        plist["ProcessType"] = "Interactive"
        plist["StandardOutPath"] = expandedPath(updatedSettings.logPath)
        plist["StandardErrorPath"] = expandedPath(updatedSettings.logPath)

        // Splash resolves its Hugging Face cache through huggingface_hub, which
        // honors HF_HUB_CACHE. Pointing it at the configured directory lets the
        // user keep (or move) model downloads to a visible home folder without
        // touching Splash. Create the directory so a fresh location works on
        // the very next model load.
        var environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        environment["HF_HUB_CACHE"] = expandedPath(updatedSettings.modelCacheDirectory)
        plist["EnvironmentVariables"] = environment
        try? FileManager.default.createDirectory(
            atPath: expandedPath(updatedSettings.modelCacheDirectory),
            withIntermediateDirectories: true
        )

        let oldTarget = "gui/\(uid)/\(previousSettings.launchdLabel)"
        let newTarget = "gui/\(uid)/\(updatedSettings.launchdLabel)"
        if newTarget != oldTarget && !sh("launchctl print \(shellQuote(newTarget)) >/dev/null 2>&1 && echo yes").isEmpty {
            return tr("validate.labeltaken")
        }

        if restartLoadedService {
            // A loaded model takes a few seconds to shut down; booting out
            // while it is still winding down leaves the service "exiting",
            // and the bootstrap below then fails with a duplicate service
            // name. So stop the process for real before unloading. A failed
            // kill is not fatal: the bootout below falls back to today's
            // behavior in that case.
            if servicePID(oldTarget) != nil {
                _ = runCommand("/bin/launchctl", ["kill", "SIGTERM", oldTarget])
                _ = waitForServiceToStop(oldTarget)
            }
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
        // A RunAtLoad=false agent is loaded but inert after the bootstrap;
        // "apply and restart" means the server must come back with the new
        // arguments, so kick the job when nothing is running yet.
        if servicePID(newTarget) == nil {
            _ = runCommand("/bin/launchctl", ["kickstart", newTarget])
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

    /// `closeAs` is the response the window's close button produces when the
    /// modal session ends. Two-button alerts map it to their second (cancel)
    /// button, which is the least committal one; three-button alerts must be
    /// told explicitly, since their second button is an actual action.
    func runClosableAlert(
        _ alert: NSAlert,
        closeAs closeResponse: NSApplication.ModalResponse = .alertSecondButtonReturn
    ) -> NSApplication.ModalResponse {
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
        activeModalCloseResponse = closeResponse
        let response = alert.runModal()
        activeModalAlertWindow = nil
        return response
    }

    @objc func closeModalAlert(_ sender: NSButton) {
        let window = sender.window ?? activeModalAlertWindow
        NSApp.stopModal(withCode: activeModalCloseResponse)
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
            let localVersions = localSplashVersions()
            DispatchQueue.main.async {
                // The GitHub release list and the locally installed versions
                // are merged into one selector: releases that are also present
                // locally are marked (installed), and locally installed
                // versions missing from the release list are offered as well.
                // When the release list cannot be loaded at all (no network,
                // GitHub down), the locally installed versions are the only
                // entries; without any of them there is nothing to select.
                let releaseVersions = releases.map(\.version)
                let mergedVersions = (releaseVersions
                    + localVersions.filter { !releaseVersions.contains($0) })
                    .sorted { lhs, rhs in
                        guard let result = compareVersions(lhs, rhs), result != .orderedSame else { return lhs > rhs }
                        return result == .orderedDescending
                    }
                guard !mergedVersions.isEmpty else {
                    self.finishVersionChange()
                    self.showSettingsError(tr("settings.error.releases"))
                    return
                }

                let selector = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28), pullsDown: false)
                let globalTitle = tr("version.global.title", self.globalVersionString())
                let globalItem = NSMenuItem(title: globalTitle, action: nil, keyEquivalent: "")
                globalItem.representedObject = SplashBarSettings.globalVersion
                selector.menu?.addItem(globalItem)
                for version in mergedVersions {
                    let suffix = localVersions.contains(version) ? tr("version.installed") : ""
                    let item = NSMenuItem(title: version + suffix, action: nil, keyEquivalent: "")
                    item.representedObject = version
                    selector.menu?.addItem(item)
                }

                // Preselect the current selection; a selection that is no
                // longer offered (or a missing global install) falls back to Global.
                let currentSelection = self.settings.selectedVersion
                if currentSelection == SplashBarSettings.globalVersion {
                    selector.selectItem(at: 0)
                } else if let index = mergedVersions.firstIndex(of: currentSelection) {
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
                // The item's represented object (not its display title, which
                // carries the (installed) suffix) is the version to switch to.
                let version = selector.menu?.item(at: selector.indexOfSelectedItem)?.representedObject as? String
                    ?? SplashBarSettings.globalVersion
                self.switchToSplashVersion(version, releases: releases)
            }
        }
    }

    /// The PID of the service's process, or nil when the service is not
    /// running — including when it is loaded but idle (a loaded agent with
    /// no process shows no usable `pid` line, or `pid = 0`).
    func servicePID(_ serviceTarget: String) -> String? {
        let result = runCommand("/bin/launchctl", ["print", serviceTarget])
        guard result.status == 0 else { return nil }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "pid", let pid = Int(parts[1]), pid > 0 {
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

            // A confirmed download cancel aborts the whole version change:
            // the previously active version stays selected, and the partially
            // created version directory was already removed.
            if errorText != nil, self.isVersionDownloadCancelled() {
                versionChangeDiagnostics.record("Download cancelled by the user; the version directory was removed.")
                versionChangeDiagnostics.end()
                DispatchQueue.main.async {
                    self.finishVersionChange()
                    self.completeVersionProgress(message: tr("version.cancelled", version), error: nil, logURL: nil)
                }
                return
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
                    // A loaded agent may have no running process (for example
                    // after Stop); `launchctl kill` would then fail and abort
                    // the whole switch, so only signal an actually running one.
                    if self.servicePID(serviceTarget) != nil {
                        let stopped = runCommand("/bin/launchctl", ["kill", "SIGTERM", serviceTarget])
                        if stopped.status != 0 || !self.waitForServiceToStop(serviceTarget) {
                            errorText = tr("version.error.stopstuck", stopped.output)
                        }
                    } else {
                        versionChangeDiagnostics.record("Service has no running process; skipping the kill step.")
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

        let cancelButton = NSButton(title: tr("version.cancel"), target: self, action: #selector(cancelVersionDownload))
        cancelButton.frame = NSRect(x: 24, y: 18, width: 82, height: 28)
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        content.addSubview(cancelButton)

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
        versionCancelButton = cancelButton
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
        versionCancelButton?.isHidden = true
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
        versionCancelButton = nil
        versionCloseButton = nil
        versionProgressLogURL = nil
    }

    /// The progress window's cancel button, shown while a release download
    /// is running. The user must confirm the cancellation first; only then
    /// is the download killed and the partially created version directory
    /// deleted.
    @objc func cancelVersionDownload() {
        // Only an in-flight download can be cancelled; if it has finished in
        // the meantime the claim below fails and nothing happens.
        guard isVersionDownloadActive() else { return }

        let version = versionDownloadVersion()
        let alert = NSAlert()
        alert.messageText = tr("version.cancelconfirm.title", version)
        alert.informativeText = tr("version.cancelconfirm.detail", version)
        alert.addButton(withTitle: tr("version.cancelconfirm.confirm"))
        alert.addButton(withTitle: tr("version.cancelconfirm.keep"))
        // Closing the dialog keeps the download running (least committal).
        guard runClosableAlert(alert) == .alertFirstButtonReturn else { return }

        guard claimVersionDownloadCancellation() else {
            return  // The download finished while the user was deciding.
        }
        // Immediate feedback while the background thread terminates curl and
        // removes the version directory.
        showVersionPhase(tr("version.cancelling", version), spinner: true)
    }

    /// Updates the progress window text and shows the spinner (indeterminate
    /// phase). Must be called on the main thread.
    func showVersionPhase(_ text: String, spinner: Bool) {
        versionProgressText?.stringValue = text
        versionProgressSpinner?.isHidden = !spinner
        versionProgressBar?.isHidden = spinner
        versionCancelButton?.isHidden = true
    }

    /// Updates the download progress bar. Must be called on the main thread.
    func showVersionDownloadProgress(_ version: String, downloaded: Int, total: Int) {
        // A queued update from before a confirmed cancel must not unhide the
        // bar or the cancel button again.
        guard !isVersionDownloadCancelled() else { return }
        versionProgressSpinner?.isHidden = true
        versionProgressBar?.isHidden = false
        versionCancelButton?.isHidden = false
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

    /// Sets whether the download progress poller runs. Starting a download
    /// also clears the cancellation flag of any earlier run.
    func setVersionDownloadActive(_ active: Bool) {
        versionDownloadLock.lock()
        defer { versionDownloadLock.unlock() }
        versionDownloadActive = active
        if active { versionDownloadCancelled = false }
    }

    func isVersionDownloadActive() -> Bool {
        versionDownloadLock.lock()
        defer { versionDownloadLock.unlock() }
        return versionDownloadActive
    }

    func isVersionDownloadCancelled() -> Bool {
        versionDownloadLock.lock()
        defer { versionDownloadLock.unlock() }
        return versionDownloadCancelled
    }

    /// The version whose download is in flight, for the cancel dialog.
    func versionDownloadVersion() -> String {
        versionDownloadLock.lock()
        defer { versionDownloadLock.unlock() }
        return versionDownloadVersionText
    }

    func setVersionDownloadVersion(_ version: String) {
        versionDownloadLock.lock()
        versionDownloadVersionText = version
        versionDownloadLock.unlock()
    }

    /// Atomically claims the right to cancel: succeeds only while the
    /// download is still running. The poller then stops and the download
    /// loop sees the cancellation and cleans up.
    func claimVersionDownloadCancellation() -> Bool {
        versionDownloadLock.lock()
        defer { versionDownloadLock.unlock() }
        guard versionDownloadActive else { return false }
        versionDownloadActive = false
        versionDownloadCancelled = true
        return true
    }

    // MARK: - Model backup and restore (emergency fallback)
    //
    // The model weights live in the Hugging Face cache (by default
    // ~/.cache/huggingface/hub); the Application Support tree only holds
    // references to it. If the user deletes that cache, the only way back is
    // a fresh multi-GB download. These two menu commands keep a local tar
    // archive in ~/SplashBar-Backups so the model can come back offline.
    // The restore is transactional: the existing cache is moved aside first
    // and put back if the archive does not extract cleanly.

    private let backupLock = NSLock()
    private var backupRunning = false
    private var backupCancelled = false
    private var backupProgressWindow: NSWindow?
    private var backupProgressText: NSTextField?
    private var backupProgressBar: NSProgressIndicator?
    private var backupProgressSpinner: NSProgressIndicator?
    private var backupCancelButton: NSButton?
    private var backupCloseButton: NSButton?
    private var backupProgressPoller: Timer?

    func modelBackupsDirectory() -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("SplashBar-Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Existing backup archives, newest first. The file names embed the
    /// creation timestamp (models-<unixtime>.tar), so a lexical sort is a
    /// chronological sort.
    func listModelBackups() -> [URL] {
        let directory = modelBackupsDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return files
            .filter { $0.pathExtension == "tar" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// The Hugging Face cache directory the server uses.
    func currentModelCacheURL() -> URL {
        URL(fileURLWithPath: expandedPath(settings.modelCacheDirectory))
    }

    func setBackupRunning(_ running: Bool) {
        backupLock.lock()
        defer { backupLock.unlock() }
        backupRunning = running
        if running { backupCancelled = false }
    }

    func isBackupRunning() -> Bool {
        backupLock.lock()
        defer { backupLock.unlock() }
        return backupRunning
    }

    func claimBackupCancellation() -> Bool {
        backupLock.lock()
        defer { backupLock.unlock() }
        guard backupRunning else { return false }
        backupCancelled = true
        return true
    }

    func isBackupCancelled() -> Bool {
        backupLock.lock()
        defer { backupLock.unlock() }
        return backupCancelled
    }

    /// Creates a tar archive of the model cache in ~/SplashBar-Backups.
    @objc func backupModel() {
        let cache = currentModelCacheURL()
        var isDirectory: ObjCBool = false
        let totalBytes = folderSize(of: cache)
        guard FileManager.default.fileExists(atPath: cache.path, isDirectory: &isDirectory),
              isDirectory.boolValue, totalBytes > 0 else {
            let alert = NSAlert()
            alert.messageText = tr("backup.error.empty")
            alert.informativeText = tr("backup.error.empty.detail", cache.path)
            runClosableAlert(alert)
            return
        }

        let confirm = NSAlert()
        confirm.messageText = tr("backup.title")
        confirm.informativeText = tr("backup.confirm", formatBytes(Int(totalBytes)), cache.path)
        confirm.addButton(withTitle: tr("backup.start"))
        confirm.addButton(withTitle: tr("settings.cancel"))
        guard runClosableAlert(confirm) == .alertFirstButtonReturn else { return }

        let destination = modelBackupsDirectory()
            .appendingPathComponent("models-\(Int(Date().timeIntervalSince1970)).tar")
        setBackupRunning(true)
        showBackupProgress(tr("backup.progress", cache.lastPathComponent), totalBytes: totalBytes, destination: destination)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = runCommand(
                "/usr/bin/tar",
                ["-cf", destination.path, "-C", cache.deletingLastPathComponent().path, cache.lastPathComponent],
                isCancelled: { self.isBackupCancelled() }
            )
            let cancelled = self.isBackupCancelled()
            self.setBackupRunning(false)
            self.backupProgressPoller?.invalidate()
            self.backupProgressPoller = nil
            DispatchQueue.main.async {
                self.backupProgressSpinner?.stopAnimation(nil)
                self.backupProgressSpinner?.isHidden = true
                self.backupProgressText?.stringValue = self.backupResultText(
                    result: result,
                    cancelled: cancelled,
                    success: tr("backup.done", destination.path),
                    failure: tr("backup.error"),
                    unknown: tr("backup.error.unknown")
                )
                self.backupCancelButton?.isHidden = true
                self.backupCloseButton?.isHidden = false
            }
        }
    }

    /// Restores the model cache from a backup archive, transactionally.
    @objc func restoreModel() {
        let cache = currentModelCacheURL()
        let backups = listModelBackups()
        guard !backups.isEmpty else {
            let alert = NSAlert()
            alert.messageText = tr("restore.error.none")
            alert.informativeText = tr("restore.error.none.detail", modelBackupsDirectory().path)
            runClosableAlert(alert)
            return
        }

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 0, height: 0), pullsDown: false)
        popup.addItems(withTitles: backups.map { $0.lastPathComponent })
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 40))
        let label = NSTextField(labelWithString: tr("restore.field"))
        label.frame = NSRect(x: 0, y: 8, width: 150, height: 24)
        popup.frame = NSRect(x: 155, y: 8, width: 335, height: 26)
        accessory.addSubview(label)
        accessory.addSubview(popup)

        let alert = NSAlert()
        alert.messageText = tr("restore.title")
        alert.informativeText = tr("restore.info", cache.path)
        alert.accessoryView = accessory
        alert.addButton(withTitle: tr("restore.start"))
        alert.addButton(withTitle: tr("settings.cancel"))
        guard runClosableAlert(alert) == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < backups.count else { return }
        let archive = backups[index]

        let parent = cache.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        // Move the existing cache aside before extracting, so a failed
        // extraction can put it back and never leaves a half-restore behind.
        var asideURL: URL?
        if FileManager.default.fileExists(atPath: cache.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            asideURL = parent.appendingPathComponent(cache.lastPathComponent + "-\(stamp)-old", isDirectory: true)
            do {
                try FileManager.default.moveItem(at: cache, to: asideURL!)
            } catch {
                let moveAlert = NSAlert()
                moveAlert.messageText = tr("restore.error")
                moveAlert.informativeText = error.localizedDescription
                runClosableAlert(moveAlert)
                return
            }
        }

        setBackupRunning(true)
        showBackupProgress(tr("restore.progress", archive.lastPathComponent), totalBytes: nil, destination: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = runCommand(
                "/usr/bin/tar",
                ["-xf", archive.path, "-C", parent.path],
                isCancelled: { self.isBackupCancelled() }
            )
            let cancelled = self.isBackupCancelled()
            let extracted = FileManager.default.fileExists(atPath: cache.path)
            var failureDetail: String?
            if result.status != 0 || !extracted {
                // Roll the transaction back: remove the partial extraction and
                // move the old cache back into place.
                try? FileManager.default.removeItem(at: cache)
                if let asideURL {
                    do {
                        try FileManager.default.moveItem(at: asideURL, to: cache)
                    } catch {
                        failureDetail = error.localizedDescription
                    }
                }
            } else if let asideURL {
                try? FileManager.default.removeItem(at: asideURL)
            }
            self.setBackupRunning(false)
            self.backupProgressPoller?.invalidate()
            self.backupProgressPoller = nil
            DispatchQueue.main.async {
                self.backupProgressSpinner?.stopAnimation(nil)
                self.backupProgressSpinner?.isHidden = true
                self.backupProgressBar?.isHidden = true
                if let failureDetail {
                    self.backupProgressText?.stringValue = tr("restore.error", failureDetail)
                } else {
                    self.backupProgressText?.stringValue = self.backupResultText(
                        result: result,
                        cancelled: cancelled,
                        success: tr("restore.done"),
                        failure: tr("restore.error"),
                        unknown: tr("restore.error.unknown")
                    )
                }
                self.backupCancelButton?.isHidden = true
                self.backupCloseButton?.isHidden = false
            }
        }
    }

    /// Maps a finished command onto the progress window's result text: a
    /// user cancellation wins over the (expected) non-zero exit status.
    func backupResultText(result: CommandResult, cancelled: Bool, success: String, failure: String, unknown: String) -> String {
        if cancelled {
            return tr("backup.cancelled")
        }
        guard result.status == 0 else {
            return tr(failure, result.output.isEmpty ? unknown : result.output)
        }
        return success
    }

    /// The shared progress window for backup and restore. `totalBytes` of
    /// `destination` is polled for the bar; `nil` shows an indeterminate bar
    /// instead (the restore has no reliable total).
    func showBackupProgress(_ text: String, totalBytes: Int64?, destination: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("window.title")
        window.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 540, height: 210))
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: 24, y: 88, width: 492, height: 100)
        label.font = .systemFont(ofSize: 14)
        content.addSubview(label)

        let bar = NSProgressIndicator(frame: NSRect(x: 24, y: 52, width: 400, height: 20))
        bar.style = .bar
        bar.isIndeterminate = totalBytes == nil || totalBytes == 0
        bar.minValue = 0
        bar.maxValue = Double(max(totalBytes ?? 1, 1))
        bar.doubleValue = 0
        content.addSubview(bar)

        let spinner = NSProgressIndicator(frame: NSRect(x: 436, y: 46, width: 20, height: 20))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        content.addSubview(spinner)

        let cancelButton = NSButton(title: tr("version.cancel"), target: self, action: #selector(cancelBackupProgress))
        cancelButton.frame = NSRect(x: 24, y: 18, width: 82, height: 28)
        cancelButton.bezelStyle = .rounded
        content.addSubview(cancelButton)

        let closeButton = NSButton(title: tr("settings.close"), target: self, action: #selector(closeBackupProgress))
        closeButton.frame = NSRect(x: 426, y: 18, width: 82, height: 28)
        closeButton.bezelStyle = .rounded
        closeButton.isHidden = true
        content.addSubview(closeButton)

        window.contentView = content
        backupProgressWindow = window
        backupProgressText = label
        backupProgressBar = bar
        backupProgressSpinner = spinner
        backupCancelButton = cancelButton
        backupCloseButton = closeButton
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if let destination {
            backupProgressPoller = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard let self, self.isBackupRunning() else {
                    timer.invalidate()
                    return
                }
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                self.backupProgressBar?.doubleValue = Double(min(Int64(size), totalBytes ?? Int64(size)))
            }
        }
    }

    @objc func cancelBackupProgress() {
        guard claimBackupCancellation() else { return }
        backupCancelButton?.isHidden = true
        backupProgressText?.stringValue = tr("backup.cancelling")
    }

    @objc func closeBackupProgress() {
        backupProgressPoller?.invalidate()
        backupProgressPoller = nil
        backupProgressWindow?.close()
        backupProgressWindow = nil
        backupProgressText = nil
        backupProgressBar = nil
        backupProgressSpinner = nil
        backupCancelButton = nil
        backupCloseButton = nil
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
        setVersionDownloadVersion(version)
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

        let download = runCommand(
            "/usr/bin/curl",
            ["--fail", "--silent", "--show-error", "--location",
             "--output", archiveURL.path,
             release.archiveURL],
            isCancelled: { [weak self] in self?.isVersionDownloadCancelled() ?? false }
        )
        setVersionDownloadActive(false)
        guard download.status == 0 else {
            if isVersionDownloadCancelled() {
                // Confirmed cancel: remove the version directory and any
                // staging leftovers, then report the cancellation.
                removeCancelledVersionArtifacts(forVersion: version)
                return tr("version.cancelled", version)
            }
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

    /// Removes the artifacts of a cancelled version download: the version
    /// directory `~/.splashbar/splash-versions/<version>` and any staging
    /// directories left behind for that version. The in-flight archive file
    /// is removed by the `defer` in `ensureLocalVersion`.
    func removeCancelledVersionArtifacts(forVersion version: String) {
        let fileManager = FileManager.default
        let versionsRoot = splashVersionsDirectory()
        try? fileManager.removeItem(
            at: versionsRoot.appendingPathComponent(version, isDirectory: true)
        )
        if let entries = try? fileManager.contentsOfDirectory(atPath: versionsRoot.path) {
            for entry in entries where entry.hasPrefix(".\(version)-staging-") {
                try? fileManager.removeItem(at: versionsRoot.appendingPathComponent(entry))
            }
        }
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
        // The rest of the file is preserved on version switches, so sync the
        // RunAtLoad key with the launch-at-login preference explicitly; a
        // stale value (for example true from an older build) would otherwise
        // survive and launch the executable at login without the app.
        plist["ProgramArguments"] = arguments
        plist["RunAtLoad"] = settings.launchAtLogin
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

    /// Kills the running splash instance before the app exits so its model
    /// memory is released. Without a running instance the app simply closes.
    /// The dot turns orange while the SIGTERM is delivered, and the app exits
    /// afterwards whether or not the process actually stopped in time — a
    /// failed kill (for example the process died in the meantime) must not
    /// keep the app alive.
    @objc func quit() {
        isQuitting = true
        startItem.isEnabled = false
        stopItem.isEnabled = false
        restartItem.isEnabled = false
        versionItem.isEnabled = false

        let serviceTarget = target
        DispatchQueue.global(qos: .userInitiated).async {
            // A loaded agent without a process (for example after Stop) has
            // nothing to kill; `launchctl kill` would just fail for it.
            if self.servicePID(serviceTarget) != nil {
                DispatchQueue.main.async {
                    self.setDot(.systemOrange)
                }
                let stopped = runCommand("/bin/launchctl", ["kill", "SIGTERM", serviceTarget])
                if stopped.status == 0 {
                    _ = self.waitForServiceToStop(serviceTarget)
                }
            }
            // Exit anyway, even when the SIGTERM failed or the instance is
            // still alive after the timeout.
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
