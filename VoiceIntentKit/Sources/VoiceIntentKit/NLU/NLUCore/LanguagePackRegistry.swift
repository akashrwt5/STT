// LanguagePackRegistry.swift
// VoiceIntentKit
//
// Discovers all `LanguagePack` manifests in
// `Bundle.module/LanguagePacks/<code>/manifest.json` at first access and
// caches them. Callers ask "what languages exist?" and "which
// ClassifierBundle does this pack use?" — never the flat resource layout.
//
// Adding a language: drop a `<code>/manifest.json` + its resources under
// `Resources/LanguagePacks/` and the pack shows up in `availableLanguages()`
// on next launch. No Swift changes.

import Foundation
import os.log

public enum LanguagePackRegistry {

    private static let log = Logger(subsystem: "com.voiceintentkit", category: "LanguagePackRegistry")

    // MARK: - Public API

    /// All packs discovered in the bundle, sorted by language code. Feed
    /// directly into a picker.
    public static func availableLanguages() -> [LanguagePack] {
        cache.values.sorted { $0.language < $1.language }
    }

    /// Look up a pack by NLU language tag ("en", "fr", ...). Nil ⇒ unknown.
    public static func pack(for code: String) -> LanguagePack? {
        cache[code]
    }

    /// Build the concrete `ClassifierBundle` a pack should use.
    ///
    /// Purely data-driven: every field flows from the manifest's `classifier`
    /// object. Adding a language ⇒ new manifest with new model/weights names.
    /// No Swift edit.
    public static func classifierBundle(for pack: LanguagePack) -> ClassifierBundle {
        ClassifierBundle(spec: pack.classifier)
    }

    // MARK: - Internal

    /// Lazily loaded manifest cache. Bundle scans happen exactly once per
    /// process; every subsequent lookup is an O(1) dictionary read.
    private static let cache: [String: LanguagePack] = loadAll()

    private static func loadAll() -> [String: LanguagePack] {
        // Packs live in `Resources/LanguagePacks/<code>/`. That whole tree is
        // shipped via `.copy(...)` so subdirectory structure is preserved in
        // the built bundle. Enumerate the top-level directory to find each
        // pack's manifest.
        guard let resourceURL = Bundle.module.resourceURL else {
            log.error("Bundle.module.resourceURL is nil — no manifests can be loaded")
            return [:]
        }
        let packsDir = resourceURL.appendingPathComponent("LanguagePacks", isDirectory: true)
        let fm = FileManager.default
        let langDirs = (try? fm.contentsOfDirectory(
            at: packsDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        let decoder = JSONDecoder()
        var result: [String: LanguagePack] = [:]
        for dir in langDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL) else {
                log.error("No manifest.json in pack \(dir.lastPathComponent, privacy: .public)")
                continue
            }
            do {
                let pack = try decoder.decode(LanguagePack.self, from: data)
                result[pack.language] = pack
            } catch {
                log.error("Failed to decode manifest for \(dir.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let codes = result.keys.sorted().joined(separator: ", ")
        log.info("LanguagePackRegistry loaded \(result.count) pack(s): \(codes, privacy: .public)")
        return result
    }
}
