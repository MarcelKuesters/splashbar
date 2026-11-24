// ModelCatalog.swift
// The models Splash suggests, mirroring the upstream
// install/suggested-models.tsv (Apache-2.0, incoai/splash):
// MODEL_ID NAME MEMORY SIZE ABOUT — MEMORY is the smallest Mac memory the
// variant is meant for, SIZE is the whole package (model, its vision
// projector if it has one, and its DFlash2 draft).
// The download window offers, per name, the variant with the most MEMORY
// that the Mac has — the same rule the upstream app applies.

import Foundation

struct ModelCatalog {
    struct Entry: Hashable, Codable {
        let id: String
        let name: String
        let memoryGB: Int
        let downloadGB: Int
        /// Localization key for the one-line positioning text.
        let aboutKey: String
        /// Splash also loads MLX checkpoints, but our downloader fetches
        /// GGUF repos only; MLX rows are kept for completeness.
        let isMLX: Bool

        var description: String {
            "\(name) · \(tr(aboutKey)) · \(downloadGB) GB · \(tr("download.ram", String(memoryGB)))"
        }
    }

    let allEntries: [Entry]

    init() {
        // The three models this app supports end to end — GGUF only (our
        // downloader fetches GGUF repos; MLX rows would download nothing).
        // Beside the 36 GB variants, the smaller quant variants stay listed
        // so the per-machine rule (suggestions) can offer Qwen on 24 GB
        // Macs. Flash-Next (64-113 GB) and Ornith (128 GB) fit no consumer
        // Mac; Flint is a text-only family without a GGUF package we tested.
        self.allEntries = [
            // Qwen3.6-35B-A3B — Fast all-rounder
            Entry(id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M", name: "Qwen3.6-35B-A3B",
                  memoryGB: 36, downloadGB: 24,
                  aboutKey: "model.about.allrounder", isMLX: false),
            Entry(id: "unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL", name: "Qwen3.6-35B-A3B",
                  memoryGB: 24, downloadGB: 14,
                  aboutKey: "model.about.allrounder", isMLX: false),

            // Qwen3.8-27B — Strongest at this size, slower
            Entry(id: "unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", name: "Qwen3.8-27B",
                  memoryGB: 36, downloadGB: 21,
                  aboutKey: "model.about.strongest", isMLX: false),
            Entry(id: "unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS", name: "Qwen3.8-27B",
                  memoryGB: 24, downloadGB: 16,
                  aboutKey: "model.about.strongest", isMLX: false),

            // Ternary-Bonsai-2-27B — Smallest download
            Entry(id: "prism-ml/Ternary-Bonsai-2-27B-gguf:PQ2_0", name: "Ternary-Bonsai-2-27B",
                  memoryGB: 24, downloadGB: 12,
                  aboutKey: "model.about.smallest", isMLX: false)
        ]
    }

    /// One entry per model name: the GGUF variant with the most MEMORY that
    /// fits the available memory, as the upstream app offers them. Names
    /// with no fitting GGUF variant are left out.
    func suggestions(memoryGB: Int) -> [Entry] {
        var byName: [String: [Entry]] = [:]
        for entry in allEntries where !entry.isMLX {
            byName[entry.name, default: []].append(entry)
        }
        return byName.keys.sorted().compactMap { name in
            byName[name]?
                .filter { $0.memoryGB <= memoryGB }
                .max { $0.memoryGB < $1.memoryGB }
        }
    }

    /// Whether a model's repo already sits in the Hugging Face Hub cache
    /// with at least one GGUF snapshot — the layout our downloads and
    /// Splash's own installer produce.
    func isInstalled(_ entry: Entry) -> Bool {
        let repo = baseRepo(of: entry.id)
        let repoFolder = URL(fileURLWithPath: NSHomeDirectory() + "/.cache/huggingface/hub/models--"
                                + repo.replacingOccurrences(of: "/", with: "--"))
        let snapshots = repoFolder.appendingPathComponent("snapshots", isDirectory: true)
        guard let revisions = fileManagerContents(ofDirectory: snapshots) else { return false }
        for revision in revisions {
            let dir = snapshots.appendingPathComponent(revision, isDirectory: true)
            if let files = fileManagerContents(ofDirectory: dir),
               files.contains(where: { $0.hasSuffix(".gguf") }) {
                return true
            }
        }
        return false
    }

    /// Returns the display name for a model ID, or falls back to repo name.
    func displayName(for id: String) -> String {
        allEntries.first(where: { $0.id == id })?.name
            ?? id.split(separator: ":").first.map(String.init)
            ?? id
    }

    /// Checks if the given model ID is one of our known suggestions.
    func isKnown(_ id: String) -> Bool {
        allEntries.contains { $0.id == id }
    }
}

/// Directory listing as plain file names; nil when the directory is absent.
private func fileManagerContents(ofDirectory directory: URL) -> [String]? {
    try? FileManager.default.contentsOfDirectory(atPath: directory.path)
}
