// DownloadManager.swift
// Manages model downloads with progress tracking and UI integration.
// Coordinates between ModelCatalog and HuggingFaceDownloader.
// Based on patterns from incoai/splash (Apache-2.0).

import Foundation

class DownloadManager {
    // MARK: - Types
    
    enum State: Equatable {
        case idle
        case downloading
        case complete
        case failed(String)
        
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.downloading, .downloading), (.complete, .complete):
                return true
            case (.failed, .failed):
                return true  // Don't compare error messages for equality
            default:
                return false
            }
        }
    }
    
    struct ModelDownloadState {
        let entry: ModelCatalog.Entry
        var state: State
        var downloadedBytes: Int64
        var totalBytes: Int64
        var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(downloadedBytes) / Double(totalBytes)
        }
        
        init(entry: ModelCatalog.Entry) {
            self.entry = entry
            self.state = .idle
            self.downloadedBytes = 0
            self.totalBytes = 0
        }
    }
    
    // MARK: - State
    
    private let downloader = HuggingFaceDownloader()
    private var downloadStates: [String: ModelDownloadState] = [:]  // keyed by model ID
    /// Bytes already received per file ("modelID/fileName" -> bytes).
    /// URLSession reports the cumulative total per file; this map replaces
    /// the value instead of adding it up again.
    private var fileProgress: [String: Int64] = [:]
    private let fileManager = FileManager.default
    
    private func isFailedState(_ state: State) -> Bool {
        if case .failed = state { return true }
        return false
    }
    
    // MARK: - Callbacks
    
    var onStateChanged: ((String, State) -> Void)?  // modelID, newState
    var onProgressUpdated: ((String, ModelDownloadState) -> Void)?
    var onAllComplete: (() -> Void)?
    
    // MARK: - Public API
    
    /// Get the download state for a model.
    func downloadState(for modelID: String) -> ModelDownloadState? {
        downloadStates[modelID]
    }
    
    /// Get all download states.
    var allStates: [ModelDownloadState] {
        Array(downloadStates.values).sorted { $0.entry.name < $1.entry.name }
    }
    
    /// Check if any download is in progress.
    var isDownloading: Bool {
        downloader.isDownloading || downloadStates.values.contains { $0.state == .downloading }
    }
    
    /// Start downloading a model.
    func startDownload(for entry: ModelCatalog.Entry) {
        // Check for existing state
        if let existingState = downloadStates[entry.id],
           existingState.state == .complete || isFailedState(existingState.state) {
            // Reset and re-download
            downloadStates[entry.id] = ModelDownloadState(entry: entry)
        } else if downloadStates[entry.id] == nil {
            downloadStates[entry.id] = ModelDownloadState(entry: entry)
        }
        
        guard var state = downloadStates[entry.id] else { return }
        state.state = .downloading
        downloadStates[entry.id] = state
        onStateChanged?(entry.id, .downloading)
        // A fresh (re)start begins at zero: drop stale per-file progress.
        fileProgress = fileProgress.filter { !$0.key.hasPrefix(entry.id + "/") }

        // Fetch repo info to get file list. The completion arrives on a
        // background queue; all state mutations are funneled onto the main
        // queue so the downloadStates dictionary is only touched there.
        HuggingFaceAPI.listRepoFiles(modelID: entry.id) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
            switch result {
            case .success(let repoInfo):
                // Destination: the Hugging Face Hub cache in its standard
                // layout, which Splash itself reads
                // (~/.cache/huggingface/hub/models--OWNER--REPO/snapshots/<commit>).
                let hubRoot = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/huggingface/hub")
                let repoFolderName = "models--" + baseRepo(of: entry.id).replacingOccurrences(of: "/", with: "--")
                let repoFolder = hubRoot.appendingPathComponent(repoFolderName, isDirectory: true)
                let commit = repoInfo.commitSHA ?? "main"
                let snapshotDir = repoFolder
                    .appendingPathComponent("snapshots", isDirectory: true)
                    .appendingPathComponent(commit, isDirectory: true)
                let modelIDDir = snapshotDir

                do {
                    try self.fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
                    // refs/main records the commit, as huggingface_hub and
                    // splash serve do.
                    let refsDir = repoFolder.appendingPathComponent("refs", isDirectory: true)
                    try self.fileManager.createDirectory(at: refsDir, withIntermediateDirectories: true)
                    try Data(commit.utf8).write(to: refsDir.appendingPathComponent("main"))
                    // Splash's tree record: sizes and hashes per file.
                    if !repoInfo.fileHashes.isEmpty {
                        var files: [String: [String: Any]] = [:]
                        for filePath in repoInfo.files {
                            var entryFile: [String: Any] = [:]
                            if let size = repoInfo.fileSizes[filePath] {
                                entryFile["size"] = size
                                entryFile["lfs_size"] = size
                            }
                            if let sha = repoInfo.fileHashes[filePath] { entryFile["lfs_sha256"] = sha }
                            if let blob = repoInfo.fileBlobIDs[filePath] { entryFile["blob_id"] = blob }
                            files[filePath] = entryFile
                        }
                        let treesDir = repoFolder.appendingPathComponent("trees", isDirectory: true)
                        try self.fileManager.createDirectory(at: treesDir, withIntermediateDirectories: true)
                        let tree: [String: Any] = ["format_version": 1, "files": files]
                        if let json = try? JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted, .sortedKeys]) {
                            try? json.write(to: treesDir.appendingPathComponent("\(commit).json"))
                        }
                    }
                } catch {
                    state.state = .failed(error.localizedDescription)
                    self.downloadStates[entry.id] = state
                    self.onStateChanged?(entry.id, .failed(error.localizedDescription))
                    return
                }

                // What to download: the variant's GGUFs, the repo's vision
                // projectors (mmproj) and the family's DFlash2 draft — the
                // package `splash serve` expects, which it cannot fetch
                // itself when it runs offline.
                let ggufs = repoInfo.files.filter { $0.hasSuffix(".gguf") }
                var selected = ggufs
                if let variant = quantVariant(of: entry.id) {
                    let matching = ggufs.filter { $0.contains(variant) }
                    if !matching.isEmpty { selected = matching }
                }
                // Splash picks the projector by its header and prefers
                // BF16, F32, F16 — download exactly one of them.
                // The docs: "a GGUF whose name HOLDS mmproj" — the token can
                // sit anywhere ("mmproj-BF16.gguf", "MODEL-mmproj-BF16.gguf").
                let projectorCandidates = ggufs.filter { $0.lowercased().contains("mmproj") }
                var chosenProjector: String?
                for preference in ["BF16", "F32", "F16"] {
                    if let match = projectorCandidates.first(where: { $0.uppercased().contains(preference) }) {
                        chosenProjector = match
                        break
                    }
                }
                if chosenProjector == nil { chosenProjector = projectorCandidates.first }
                let projectors = chosenProjector.map { [$0] } ?? []
                let modelRepo = baseRepo(of: entry.id)
                var targets: [(keyName: String, filePath: String, repo: String, dest: URL, sha: String?)] = []
                for filePath in selected {
                    targets.append((filePath, filePath, modelRepo, modelIDDir, repoInfo.fileHashes[filePath]))
                }
                for filePath in projectors {
                    targets.append((filePath, filePath, modelRepo, modelIDDir, repoInfo.fileHashes[filePath]))
                }
                var totalBytes: Int64 = targets.reduce(Int64(0)) { $0 + (repoInfo.fileSizes[$1.filePath] ?? 0) }

                func beginDownloads() {
                    if var currentState = self.downloadStates[entry.id] {
                        currentState.totalBytes = totalBytes
                        self.downloadStates[entry.id] = currentState
                        self.onProgressUpdated?(entry.id, currentState)
                    }

                    // Set progress and completion handlers BEFORE starting
                    // the downloads: downloadFile reports already-downloaded
                    // files synchronously, which would otherwise be missed.
                    self.downloader.onProgress = { progressTask in
                        guard progressTask.modelID == entry.id,
                              !progressTask.fileName.isEmpty,
                              var currentState = self.downloadStates[entry.id] else { return }
                        // URLSession reports the cumulative total per file:
                        // replace the per-file value, never add it up again.
                        self.fileProgress["\(progressTask.modelID)/\(progressTask.fileName)"] = progressTask.downloaded
                        let received = self.fileProgress
                            .filter { $0.key.hasPrefix(entry.id + "/") }
                            .reduce(Int64(0)) { $0 + $1.value }
                        currentState.downloadedBytes = received
                        if currentState.totalBytes <= 0, progressTask.fileSize > 0 {
                            currentState.totalBytes = progressTask.fileSize
                        }
                        self.downloadStates[entry.id] = currentState
                        self.onProgressUpdated?(entry.id, currentState)
                    }
                    self.downloader.onComplete = { [weak self] completedTask in
                        guard let self = self,
                              var currentState = self.downloadStates[entry.id] else { return }

                        if completedTask.isComplete || completedTask.cancelled || completedTask.error != nil {
                            // Record the finished file's byte count so the
                            // running sum stays correct for the rest.
                            self.fileProgress["\(completedTask.modelID)/\(completedTask.fileName)"] = completedTask.downloaded
                            // A cancelled task that did not finish is a user
                            // abort: return the model to idle so the button
                            // offers "Laden" again.
                            if completedTask.cancelled && !completedTask.isComplete {
                                currentState.state = .idle
                                self.downloadStates[entry.id] = currentState
                                self.onStateChanged?(entry.id, .idle)
                                return
                            }
                            // A network/server failure with resume data
                            // kept: report it so the button offers
                            // "Wiederholen" (and resumes).
                            if let failureMessage = completedTask.error, !completedTask.isComplete {
                                currentState.state = .failed(failureMessage)
                                self.downloadStates[entry.id] = currentState
                                self.onStateChanged?(entry.id, .failed(failureMessage))
                                return
                            }
                            // Recalculate total progress from the files on
                            // disk (symlinks count through).
                            var totalDownloaded: Int64 = 0
                            for target in targets {
                                let fileURL = target.dest.appendingPathComponent(target.filePath)
                                if let attrs = try? self.fileManager.attributesOfItem(atPath: fileURL.path),
                                   let size = attrs[.size] as? Int64 {
                                    totalDownloaded += size
                                }
                            }
                            currentState.downloadedBytes = totalDownloaded

                            let allComplete = targets.allSatisfy { target in
                                self.fileManager.fileExists(
                                    atPath: target.dest.appendingPathComponent(target.filePath).path)
                            }

                            if allComplete {
                                currentState.state = .complete
                                self.onStateChanged?(entry.id, .complete)
                                self.onAllComplete?()
                            } else if currentState.downloadedBytes > 0 {
                                self.onProgressUpdated?(entry.id, currentState)
                            }
                        }
                    }

                    // Start every file of the package (handlers in place now)
                    for target in targets {
                        _ = self.downloader.downloadFile(
                            modelID: entry.id,
                            fileName: target.filePath,
                            destinationDir: target.dest,
                            expectedSHA256: target.sha,
                            repoOverride: target.repo,
                            keyOverride: target.keyName
                        )
                    }
                }

                // The family's DFlash2 draft lives in its own repository
                // (incoai/<family>-DFlash2); Splash reads it from the Hub
                // cache. The engine's model-check names the family from the
                // GGUF's configuration, not from the repo name — Bonsai
                // (no public draft) belongs to the Qwen3.8-27B family, so
                // its draft is the one to fetch.
                let familyOverride = draftFamilyOverrides[familyName(of: entry.id)]
                let draftRepo = "incoai/\(familyOverride ?? familyName(of: entry.id))-DFlash2"
                HuggingFaceAPI.listRepoFiles(modelID: draftRepo) { [weak self] draftResult in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        switch draftResult {
                        case .success(let draftInfo):
                            let draftCommit = draftInfo.commitSHA ?? "main"
                            let draftFolder = hubRoot.appendingPathComponent(
                                "models--" + baseRepo(of: draftRepo).replacingOccurrences(of: "/", with: "--"),
                                isDirectory: true)
                            let draftSnapshot = draftFolder
                                .appendingPathComponent("snapshots", isDirectory: true)
                                .appendingPathComponent(draftCommit, isDirectory: true)
                            do {
                                try self.fileManager.createDirectory(at: draftSnapshot, withIntermediateDirectories: true)
                                let draftRefs = draftFolder.appendingPathComponent("refs", isDirectory: true)
                                try self.fileManager.createDirectory(at: draftRefs, withIntermediateDirectories: true)
                                try Data(draftCommit.utf8).write(to: draftRefs.appendingPathComponent("main"))
                            } catch {
                                appendDownloadLog("Draft-Ordner konnte nicht angelegt werden: \(error.localizedDescription)")
                            }
                            let skipped = ["\\.gitattributes$", "README\\.md$", "^assets/"]
                            for filePath in draftInfo.files
                            where !skipped.contains(where: { filePath.range(of: $0, options: .regularExpression) != nil }) {
                                // keyName only names the progress key
                                // ("DFlash2/…"); URL and destination come
                                // from filePath at the call site.
                                targets.append(("DFlash2/" + filePath, filePath, baseRepo(of: draftRepo), draftSnapshot, draftInfo.fileHashes[filePath]))
                                totalBytes += draftInfo.fileSizes[filePath] ?? 0
                            }
                        case .failure(let draftError):
                            appendDownloadLog("Draft \(draftRepo) nicht gefunden, übersprungen: \(draftError.localizedDescription)")
                        }
                        beginDownloads()
                    }
                }

            case .failure(let error):
                state.state = .failed(error.localizedDescription)
                self.downloadStates[entry.id] = state
                self.onStateChanged?(entry.id, .failed(error.localizedDescription))
            }
            }
        }
    }
    
    /// Cancel a download. The URL session tasks are cancelled by model ID;
    /// URLSession discards the partial temp files.
    func cancelDownload(for modelID: String) {
        downloader.cancelAll(for: modelID)

        guard var state = downloadStates[modelID] else { return }
        state.state = .idle
        state.downloadedBytes = 0
        state.totalBytes = 0
        downloadStates[modelID] = state
        onStateChanged?(modelID, .idle)
    }
    
    /// Reset a failed download.
    func resetFailedDownload(for modelID: String) {
        if var state = downloadStates[modelID] {
            state.state = .idle
            state.downloadedBytes = 0
            state.totalBytes = 0
            downloadStates[modelID] = state
            onStateChanged?(modelID, .idle)
        }
    }
    
    /// Clear all download states.
    func clearAllStates() {
        downloadStates.removeAll()
    }
}
