// HuggingFaceDownloader.swift
// Downloads models from Hugging Face Hub using pure Swift.
// No Python, no external dependencies — just URLSession and Foundation.
// Based on patterns from incoai/splash (Apache-2.0).

import Foundation

struct DownloadTask: Identifiable {
    let id = UUID()
    let modelID: String
    let fileName: String
    var fileSize: Int64
    var downloaded: Int64
    var cancelled: Bool
    var error: String?

    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return Double(downloaded) / Double(fileSize)
    }

    var isComplete: Bool {
        return downloaded >= fileSize && error == nil && !cancelled
    }

    init(modelID: String, fileName: String, fileSize: Int64) {
        self.modelID = modelID
        self.fileName = fileName
        self.fileSize = fileSize
        self.downloaded = 0
        self.cancelled = false
        self.error = nil
    }
}

class HuggingFaceDownloader: NSObject, URLSessionDownloadDelegate {
    // MARK: - State

    /// Active downloads, keyed by "modelID/fileName".
    private var activeTasks: [String: DownloadTask] = [:]
    /// The URLSession download task backing each key, for cancellation.
    private var sessionTasks: [String: URLSessionDownloadTask] = [:]
    /// Where each key's file belongs once the temp download finishes.
    private var destinationURLs: [String: URL] = [:]
    /// The snapshot directory each key downloads into (the Hub-cache root
    /// for blob and symlink placement).
    private var snapshotDirs: [String: URL] = [:]
    /// Expected content sha256 per key, from the tree API; names the blob.
    private var expectedHashes: [String: String] = [:]
    /// Throttling: last time a key reported progress.
    private var lastReport: [String: Date] = [:]
    /// Keys whose current attempt was started from saved resume data.
    private var usedResumeKeys: Set<String> = []
    /// URLSession resume data per key. Held in memory ONLY: resume data
    /// references URLSession's temp files, which do not survive an app
    /// restart — resuming across restarts assembled a corrupt file (caught
    /// by the checksum guard). Within one session, cancel → Laden continues
    /// from where it left off.
    private var resumeDatas: [String: Data] = [:]
    private let lock = NSLock()
    private let fileManager = FileManager.default

    /// A delegate-backed session: only the delegate API reports incremental
    /// byte progress (didWriteData); the completion-handler API would give
    /// nothing until the whole file has arrived.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // Multi-GB GGUFs transfer for hours: the request timeout only bounds
        // idle stalls between data (30 min), and the resource timeout must
        // never cap the whole transfer.
        config.timeoutIntervalForRequest = 1800
        config.timeoutIntervalForResource = 604800
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Callbacks

    var onProgress: ((DownloadTask) -> Void)?
    var onComplete: ((DownloadTask) -> Void)?
    var onDownloadFinished: (() -> Void)?

    // MARK: - Public API

    /// Downloads one file of a repo into the Hugging Face Hub cache layout.
    /// `destinationDir` is the snapshot directory of the repo
    /// (`…/models--OWNER--REPO/snapshots/<commit>`); `fileName` is the file's
    /// path relative to the repo root. When `expectedSHA256` is known (from
    /// the tree API) the content lands in `blobs/<sha256>` with a snapshot
    /// symlink, exactly as huggingface_hub lays it out.
    func downloadFile(modelID: String, fileName: String, destinationDir: URL, expectedSHA256: String? = nil, repoOverride: String? = nil, keyOverride: String? = nil) -> DownloadTask {
        // `keyOverride` decouples the progress key from the file name: the
        // DFlash2 draft's files keep their repo-local names for URL and
        // destination, but key under the draft folder so they cannot collide
        // with the model repo's own files (its config.json).
        let key = "\(modelID)/\(keyOverride ?? fileName)"

        // Check if already downloaded
        let fileURL = destinationDir.appendingPathComponent(fileName, isDirectory: false)
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? Int64 {
            var completedTask = DownloadTask(modelID: modelID, fileName: fileName, fileSize: size)
            completedTask.downloaded = size
            DispatchQueue.main.async { [self] in
                onProgress?(completedTask)
                onComplete?(completedTask)
                notifyIfAllDone()
            }
            return completedTask
        }

        let task = DownloadTask(modelID: modelID, fileName: fileName, fileSize: 0)
        lock.lock()
        activeTasks[key] = task
        lock.unlock()
        DispatchQueue.main.async { [self] in onProgress?(task) }

        // The repo part of the ID must not carry the quant variant — a URL
        // like .../REPO:UD-Q4_K_M/resolve/... answers 401. DFlash2 drafts
        // live in their own repo and pass it via repoOverride.
        let repo = repoOverride ?? baseRepo(of: modelID)
        guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)") else {
            var failed = task
            failed.error = "Invalid download URL"
            failed.cancelled = true
            finishTask(key: key, task: failed)
            return failed
        }

        // Continue a previously cancelled or failed attempt where it left
        // off, if URLSession handed us resume data for this file.
        lock.lock()
        let savedResume = resumeDatas[key]
        lock.unlock()
        let downloadTask: URLSessionDownloadTask
        if let savedResume, !savedResume.isEmpty {
            downloadTask = session.downloadTask(withResumeData: savedResume)
            lock.lock()
            usedResumeKeys.insert(key)
            lock.unlock()
        } else {
            downloadTask = session.downloadTask(with: url)
        }
        downloadTask.taskDescription = key
        lock.lock()
        sessionTasks[key] = downloadTask
        destinationURLs[key] = destinationDir.appendingPathComponent(fileName, isDirectory: false)
        snapshotDirs[key] = destinationDir
        expectedHashes[key] = expectedSHA256
        lastReport[key] = .distantPast
        lock.unlock()
        downloadTask.resume()
        return task
    }

    /// Cancels every running task of one model, keeping resume data so a
    /// later "Laden" continues instead of starting over.
    func cancelAll(for modelID: String) {
        lock.lock()
        let matching = sessionTasks.filter { $0.key.hasPrefix(modelID + "/") }
        lock.unlock()
        for (key, st) in matching {
            st.cancel { [weak self] resumeData in
                if let resumeData, !resumeData.isEmpty {
                    self?.saveResumeData(resumeData, for: key)
                }
            }
        }
    }

    func cancel(task: DownloadTask) {
        let key = "\(task.modelID)/\(task.fileName)"
        lock.lock()
        let st = sessionTasks[key]
        lock.unlock()
        st?.cancel()
    }

    var activeTasksList: [DownloadTask] {
        lock.lock(); defer { lock.unlock() }
        return Array(activeTasks.values)
    }

    var isDownloading: Bool {
        lock.lock(); defer { lock.unlock() }
        return !activeTasks.isEmpty
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let key = downloadTask.taskDescription as? String else { return }
        lock.lock()
        var task = activeTasks[key]
        task?.downloaded = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { task?.fileSize = totalBytesExpectedToWrite }
        // Report at most every 0.25 s so the UI is not flooded.
        let last = lastReport[key] ?? .distantPast
        let shouldReport = Date().timeIntervalSince(last) >= 0.25
        if shouldReport { lastReport[key] = Date() }
        if let t = task { activeTasks[key] = t }
        lock.unlock()
        if shouldReport, let t = task { onProgress?(t) }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let key = downloadTask.taskDescription else { return }
        lock.lock()
        let pendingTask = activeTasks[key]
        let destination = destinationURLs[key]
        let snapshotDir = snapshotDirs[key]
        let expectedSHA = expectedHashes[key]
        lock.unlock()
        guard var currentTask = pendingTask, let destinationURL = destination else { return }

        // URLSession deletes the temp file at `location` as soon as this
        // delegate method returns — so the file is moved to safety
        // SYNCHRONOUSLY first (a same-volume rename is cheap); only the slow
        // sha256 verification and the final placement run off the delegate
        // queue afterwards.
        let stagingURL: URL
        do {
            try? fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let expectedSHA, !expectedSHA.isEmpty, let snapshotDir {
                let repoRoot = snapshotDir.deletingLastPathComponent().deletingLastPathComponent()
                let blobsDir = repoRoot.appendingPathComponent("blobs", isDirectory: true)
                try? fileManager.createDirectory(at: blobsDir, withIntermediateDirectories: true)
                stagingURL = blobsDir.appendingPathComponent(
                    expectedSHA.lowercased() + ".staging-" + UUID().uuidString, isDirectory: false)
                try fileManager.moveItem(at: location, to: stagingURL)
            } else {
                // No hash known: the snapshot path is the final place.
                try? fileManager.removeItem(at: destinationURL)
                try fileManager.moveItem(at: location, to: destinationURL)
                stagingURL = destinationURL
            }
        } catch {
            currentTask.error = "Datei konnte nicht gesichert werden: \(error.localizedDescription)"
            removeResumeData(for: key)
            finishTask(key: key, task: currentTask)
            return
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                var placedSize: Int64 = 0
                if let expectedSHA, !expectedSHA.isEmpty, let snapshotDir, stagingURL != destinationURL {
                    // Verify the content against the hash the tree API gave,
                    // then file it under blobs/<sha256> with a snapshot
                    // symlink, exactly as huggingface_hub does.
                    guard let actual = sha256OfFile(stagingURL) else {
                        try? fileManager.removeItem(at: stagingURL)
                        throw NSError(domain: "ChecksumUnavailable", code: -1, userInfo: [NSLocalizedDescriptionKey: "Prüfsumme konnte nicht gelesen werden"])
                    }
                    guard actual.lowercased() == expectedSHA.lowercased() else {
                        try? fileManager.removeItem(at: stagingURL)
                        throw NSError(domain: "ChecksumMismatch", code: -1, userInfo: [NSLocalizedDescriptionKey: "Checksummen stimmen nicht überein"])
                    }
                    let repoRoot = snapshotDir.deletingLastPathComponent().deletingLastPathComponent()
                    let blobsDir = repoRoot.appendingPathComponent("blobs", isDirectory: true)
                    let blobURL = blobsDir.appendingPathComponent(expectedSHA.lowercased(), isDirectory: false)
                    if fileManager.fileExists(atPath: blobURL.path) {
                        try? fileManager.removeItem(at: stagingURL)
                    } else {
                        try fileManager.moveItem(at: stagingURL, to: blobURL)
                    }
                    try? fileManager.removeItem(at: destinationURL)
                    try fileManager.createSymbolicLink(atPath: destinationURL.path, withDestinationPath: "../../blobs/\(expectedSHA.lowercased())")
                    placedSize = (try? fileManager.attributesOfItem(atPath: blobURL.path))?[.size] as? Int64 ?? 0
                } else {
                    // No hash known: the file already sits in the snapshot.
                    placedSize = (try? fileManager.attributesOfItem(atPath: destinationURL.path))?[.size] as? Int64 ?? 0
                }

                currentTask.downloaded = placedSize
                currentTask.fileSize = max(currentTask.fileSize, placedSize)
                currentTask.error = nil
                // A finished download must not resume later.
                removeResumeData(for: key)
                finishTask(key: key, task: currentTask)
            } catch {
                // Checksum/save failures are real errors, not user aborts.
                currentTask.error = error.localizedDescription
                removeResumeData(for: key)
                finishTask(key: key, task: currentTask)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let key = downloadTask.taskDescription else { return }
        // Success is handled in didFinishDownloadingTo; only errors land here.
        guard let error = error else { return }
        lock.lock()
        let pendingTask = activeTasks[key]
        lock.unlock()
        var currentTask = pendingTask ?? DownloadTask(modelID: key, fileName: "", fileSize: 0)

        if (error as NSError).code == NSURLErrorCancelled {
            // A real user abort (via cancel(byProducingResumeData:), which
            // hands us the resume data separately).
            currentTask.error = nil
            currentTask.cancelled = true
        } else {
            // A network/server failure — NOT a cancel. Keep the task
            // un-cancelled so the manager reports a failure, and stash the
            // resume data URLSession offers so a retry continues instead
            // of starting over.
            currentTask.error = error.localizedDescription
            if let resumeData = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                saveResumeData(resumeData, for: key)
            } else if usedResumeKeys.contains(key) {
                // The resume data itself failed; drop it so the next attempt
                // starts fresh instead of failing in a loop.
                removeResumeData(for: key)
            }
        }
        finishTask(key: key, task: currentTask)
    }

    // MARK: - Private

    private func saveResumeData(_ data: Data, for key: String) {
        lock.lock()
        resumeDatas[key] = data
        lock.unlock()
    }

    private func removeResumeData(for key: String) {
        lock.lock()
        resumeDatas[key] = nil
        lock.unlock()
    }

    /// Marks a task finished, reports it, and clears it from the active set.
    private func finishTask(key: String, task: DownloadTask) {
        lock.lock()
        activeTasks[key] = task
        sessionTasks[key] = nil
        destinationURLs[key] = nil
        snapshotDirs[key] = nil
        expectedHashes[key] = nil
        usedResumeKeys.remove(key)
        lock.unlock()
        if task.isComplete {
            removeResumeData(for: key)
        }
        DispatchQueue.main.async { [self] in
            onComplete?(task)
            lock.lock()
            activeTasks[key] = nil
            lastReport[key] = nil
            lock.unlock()
            notifyIfAllDone()
        }
    }

    private func notifyIfAllDone() {
        if !isDownloading {
            onDownloadFinished?()
        }
    }

    /// sha256 of a file via /usr/bin/shasum, streaming — no full read in RAM.
    private func sha256OfFile(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let out = String(data: data, encoding: .utf8) else { return nil }
        return out.split(separator: " ").first.map { $0.lowercased() }
    }
}

// MARK: - Helper: Find GGUF files in a repository

struct HFRepoInfo {
    let repoID: String
    /// Every file path of the repo (no filtering — the caller decides what
    /// to download: variant GGUFs, mmproj projectors, DFlash2 drafts).
    let files: [String]
    let totalSizeBytes: Int64
    /// path -> git blob oid of the file (from the tree API)
    let fileBlobIDs: [String: String]
    /// path -> the name the Hub cache gives the blob: the LFS sha256 for
    /// LFS files, the git oid for plain files
    let fileHashes: [String: String]
    /// path -> file size in bytes
    let fileSizes: [String: Int64]
    /// the repo's current commit; names the snapshot directory
    let commitSHA: String?
}

/// A model ID may carry a quant variant after a colon, as in
/// "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M". The variant is Splash's selector,
/// not part of the Hugging Face repo name; URLs with it answer 401.
func baseRepo(of modelID: String) -> String {
    String(modelID.split(separator: ":", maxSplits: 1).first ?? Substring(modelID))
}

/// The variant suffix of a model ID, if present.
func quantVariant(of modelID: String) -> String? {
    let parts = modelID.split(separator: ":", maxSplits: 1)
    return parts.count == 2 ? String(parts[1]) : nil
}

/// The model family name of a GGUF repo: "unsloth/Qwen3.8-27B-GGUF" yields
/// "Qwen3.8-27B", which names the family's DFlash2 draft repository
/// (incoai/<family>-DFlash2).
func familyName(of modelID: String) -> String {
    let name = baseRepo(of: modelID).split(separator: "/").last.map(String.init) ?? baseRepo(of: modelID)
    for suffix in ["-GGUF", "-gguf"] where name.hasSuffix(suffix) {
        return String(name.dropLast(suffix.count))
    }
    return name
}

/// Repo-name family -> the family the splash engine's model-check actually
/// reports (install/families.py). The draft is fetched per REPORTED family.
let draftFamilyOverrides: [String: String] = [
    // Ternary-Bonsai-2-27B is a ternary quantization of the Qwen3.8-27B
    // architecture; no public draft exists for it under its own name.
    "Ternary-Bonsai-2-27B": "Qwen3.8-27B",
]

class HuggingFaceAPI {
    /// Lists every file of a repository (no filtering). `modelID` may carry
    /// a quant variant; the API call always uses the bare repo.
    static func listRepoFiles(modelID: String, completion: @escaping (Result<HFRepoInfo, Error>) -> Void) {
        let repo = baseRepo(of: modelID)
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
            completion(.failure(NSError(domain: "InvalidModelID", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid model ID"])))
            return
        }

        let request = URLRequest(url: url, timeoutInterval: 30)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(.failure(NSError(domain: "ParseError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse repository listing"])))
                return
            }

            var files: [String] = []
            var hashes: [String: String] = [:]
            var blobIDs: [String: String] = [:]
            var sizes: [String: Int64] = [:]
            var totalSize: Int64 = 0
            for entry in json {
                guard entry["type"] as? String == "file",
                      let path = entry["path"] as? String,
                      let size = entry["size"] as? Int64 else { continue }
                files.append(path)
                sizes[path] = size
                totalSize += size
                // LFS files name their blob after the content sha256; plain
                // files after the git blob oid.
                let lfs = entry["lfs"] as? [String: Any]
                if let lfsSHA = lfs?["oid"] as? String {
                    hashes[path] = lfsSHA
                } else if let gitOID = entry["oid"] as? String {
                    hashes[path] = gitOID
                }
                if let gitOID = entry["oid"] as? String { blobIDs[path] = gitOID }
            }

            // The repo's current commit names the snapshot directory of the
            // Hub cache layout.
            fetchRepoCommit(repo: repo) { commitSHA in
                completion(.success(HFRepoInfo(
                    repoID: modelID,
                    files: files,
                    totalSizeBytes: totalSize,
                    fileBlobIDs: blobIDs,
                    fileHashes: hashes,
                    fileSizes: sizes,
                    commitSHA: commitSHA
                )))
            }
        }.resume()
    }

    /// The commit the repo currently points at (`sha` of the model info).
    static func fetchRepoCommit(repo: String, completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            completion(nil)
            return
        }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 30)) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sha = json["sha"] as? String else {
                completion(nil)
                return
            }
            completion(sha)
        }.resume()
    }
}
