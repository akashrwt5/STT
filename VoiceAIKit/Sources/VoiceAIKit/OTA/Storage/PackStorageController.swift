import Foundation
import os.log

public protocol PackStorageControlling: Sendable {
    func stagingDirectory(for language: String, clean: Bool) throws -> URL
    func currentPack(for language: String) -> URL?
    func hasActivePack(for language: String) -> Bool
    func commitStagingAndActivate(version: String, for language: String) throws
    func activate(version: String, for language: String) throws
    func rollback(for language: String) throws
}

/// How many installed versions to retain on disk beyond the active one.
///
/// Retention is a *policy* (how much disk to spend on rollback safety), deliberately separated
/// from the storage *mechanism*. `keepPreviousCount == 1` keeps the active version plus the one
/// immediately before it — enough for a single rollback, and enough to protect a reader that
/// resolved the previous `Current` moments before a swap.
public struct PackRetentionPolicy: Sendable {
    /// Number of pre-active versions to keep (newest-first). Must be >= 0.
    public let keepPreviousCount: Int

    public init(keepPreviousCount: Int = 1) {
        self.keepPreviousCount = max(0, keepPreviousCount)
    }

    public static let `default` = PackRetentionPolicy()
}

/// Manages the on-disk storage layout, atomic activation, and rollback for NLU packs.
/// Enforces the filesystem as the single source of truth using atomic symbolic links.
///
/// Thread safety: all mutating operations (`stagingDirectory(clean:)`, `commitStagingAndActivate`,
/// `activate`, `rollback`, `cleanup`) are serialized by an internal lock, and the `Current`
/// symlink is swapped with the POSIX `rename(2)` syscall, which atomically replaces the
/// destination. A reader resolving `Current` therefore always sees either the old target or the
/// new one, never a missing link.
///
/// There is no mutable stored state — every property is a `let` and all mutation happens on the
/// filesystem under the lock — so the `Sendable` conformance is checked rather than asserted.
public final class PackStorageController: PackStorageControlling {
    /// The base directory provided by the Host Application (e.g. Application Support or an App Group container).
    public let baseStorageURL: URL

    /// Serializes every mutation of the on-disk layout. A single recursive lock is enough:
    /// `commitStagingAndActivate` calls `activate`, which calls `cleanup`, all on one thread.
    private let lock = NSRecursiveLock()

    /// The root directory for all VoiceAIKit data: `{baseStorageURL}/VoiceAIKit`
    private var rootURL: URL {
        baseStorageURL.appendingPathComponent("VoiceAIKit", isDirectory: true)
    }

    /// The directory containing all downloaded language packs: `{rootURL}/Packs`
    private var packsURL: URL {
        rootURL.appendingPathComponent("Packs", isDirectory: true)
    }

    /// `FileManager` is not `Sendable`, though its methods are documented as safe to call from
    /// multiple threads when no `FileManagerDelegate` is set, which is the case here.
    nonisolated(unsafe) private let fileManager: FileManager
    private let retentionPolicy: PackRetentionPolicy
    private let logger = Logger(subsystem: "com.starkey.voiceaikit", category: "PackStorage")

    /// Name of the per-language file recording the rollback target (the version that was active
    /// immediately before the current one). Hidden so it is never mistaken for a version directory.
    private let rollbackTargetFileName = ".rollback_target"

    /// Initializes the storage controller and ensures the root directory structure exists.
    public init(baseStorageURL: URL,
                fileManager: FileManager = .default,
                retentionPolicy: PackRetentionPolicy = .default) throws {
        self.baseStorageURL = baseStorageURL
        self.fileManager = fileManager
        self.retentionPolicy = retentionPolicy
        try createDirectoryStructureIfNeeded()
    }

    private func createDirectoryStructureIfNeeded() throws {
        if !fileManager.fileExists(atPath: packsURL.path) {
            try fileManager.createDirectory(at: packsURL, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: - Directory Resolution

    /// Returns the URL for a specific language directory (e.g., `Packs/en/`).
    private func languageDirectory(for language: String) throws -> URL {
        let url = packsURL.appendingPathComponent(language, isDirectory: true)
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
        return url
    }

    /// Returns the URL for the staging directory for a specific language (e.g., `Packs/en/staging/`).
    /// - Parameter clean: If true, wipes the directory before returning it to ensure a fresh state.
    public func stagingDirectory(for language: String, clean: Bool = true) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        let langDir = try languageDirectory(for: language)
        let staging = langDir.appendingPathComponent("staging", isDirectory: true)

        if clean {
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true, attributes: nil)
        }

        return staging
    }

    /// Returns the active (Current) pack URL for a given language, resolving the symbolic link.
    ///
    /// Read-only and lock-free: it resolves a single symlink that is only ever replaced atomically
    /// by `activate`, so a concurrent swap yields either the previous or the next target, never a
    /// torn read.
    public func currentPack(for language: String) -> URL? {
        guard let langDir = try? languageDirectory(for: language) else { return nil }
        let currentLink = langDir.appendingPathComponent("Current")

        // Resolve the symbolic link to the actual version directory
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: currentLink.path) else {
            return nil // No symlink exists
        }

        // Resolve the relative symlink target to an absolute URL
        let resolvedURL = langDir.appendingPathComponent(destination)

        guard fileManager.fileExists(atPath: resolvedURL.path) else {
            // Dangling symlink (target was deleted) — clean it up silently
            try? fileManager.removeItem(at: currentLink)
            return nil
        }

        return resolvedURL
    }

    /// Checks if an active OTA pack is installed for the given language.
    public func hasActivePack(for language: String) -> Bool {
        return currentPack(for: language) != nil
    }

    // MARK: - Activation & Rollback

    /// Promotes the current staging directory to a versioned directory and atomically activates it.
    public func commitStagingAndActivate(version: String, for language: String) throws {
        lock.lock(); defer { lock.unlock() }
        let langDir = try languageDirectory(for: language)
        let stagingDir = langDir.appendingPathComponent("staging", isDirectory: true)
        let versionDir = langDir.appendingPathComponent(version, isDirectory: true)

        guard fileManager.fileExists(atPath: stagingDir.path) else {
            throw PackStorageError.versionDirectoryNotFound("staging")
        }

        if fileManager.fileExists(atPath: versionDir.path) {
            try fileManager.removeItem(at: versionDir)
        }
        try fileManager.moveItem(at: stagingDir, to: versionDir)

        try activate(version: version, for: language)
    }

    /// Atomically swaps the `Current` symbolic link to point to the new version using `rename(2)`.
    ///
    /// - Parameter recordRollbackTarget: when true (the normal case), the version that was active
    ///   before this swap is recorded as the known-good rollback target. `rollback` sets it false so
    ///   rolling back does not overwrite the marker with the bad version it is leaving.
    public func activate(version: String, for language: String) throws {
        try activate(version: version, for: language, recordRollbackTarget: true)
    }

    private func activate(version: String, for language: String, recordRollbackTarget: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let langDir = try languageDirectory(for: language)
        let newVersionURL = langDir.appendingPathComponent(version, isDirectory: true)
        let currentLinkURL = langDir.appendingPathComponent("Current", isDirectory: false)

        guard fileManager.fileExists(atPath: newVersionURL.path) else {
            throw PackStorageError.versionDirectoryNotFound(version)
        }

        // The version pointed at before this swap becomes the known-good rollback target.
        let previousTarget = try? fileManager.destinationOfSymbolicLink(atPath: currentLinkURL.path)

        // Create a temporary relative symlink (e.g. pointing to "1.0.36"), then atomically
        // rename it over `Current`. POSIX rename(2) replaces the destination atomically, so there
        // is never a window where `Current` is absent (unlike removeItem + moveItem).
        let tempLinkURL = langDir.appendingPathComponent("Current_temp_\(UUID().uuidString)", isDirectory: false)
        try fileManager.createSymbolicLink(atPath: tempLinkURL.path, withDestinationPath: version)

        let result = rename(tempLinkURL.path, currentLinkURL.path)
        if result != 0 {
            let err = String(cString: strerror(errno))
            try? fileManager.removeItem(at: tempLinkURL)
            throw PackStorageError.activationSwapFailed(err)
        }

        // Record the known-good rollback target (C7): the version we just left, not "the highest
        // other version on disk". This is what stops rollback from bouncing back to a version we
        // previously rolled away from.
        if recordRollbackTarget, let previousTarget, previousTarget != version {
            writeRollbackTarget(previousTarget, in: langDir)
        }

        // Run cleanup policy after successful activation
        try cleanup(language: language, activeVersion: version)
    }

    /// Rolls back to the known-good previous version recorded at activation time (C7).
    ///
    /// Falls back to "the highest other installed version" only if no marker exists (e.g. a pack
    /// installed by an older build of this controller), preserving the previous behaviour.
    public func rollback(for language: String) throws {
        lock.lock(); defer { lock.unlock() }
        let langDir = try languageDirectory(for: language)
        let currentLinkURL = langDir.appendingPathComponent("Current", isDirectory: false)

        guard fileManager.fileExists(atPath: currentLinkURL.path) else {
            throw PackStorageError.noActivePackToRollback
        }

        let currentVersionPath = try fileManager.destinationOfSymbolicLink(atPath: currentLinkURL.path)

        // 1. Preferred: the recorded known-good target, if it is still a real, non-current version.
        if let marked = readRollbackTarget(in: langDir),
           marked != currentVersionPath,
           fileManager.fileExists(atPath: langDir.appendingPathComponent(marked, isDirectory: true).path) {
            try activate(version: marked, for: language, recordRollbackTarget: false)
            return
        }

        // 2. Fallback: highest installed version that is not the current one.
        let versions = installedVersions(in: langDir)
        guard let previousVersion = versions.filter({ $0 != currentVersionPath }).last else {
            throw PackStorageError.noPreviousVersionAvailable
        }
        try activate(version: previousVersion, for: language, recordRollbackTarget: false)
    }

    // MARK: - Rollback marker

    private func rollbackTargetURL(in langDir: URL) -> URL {
        langDir.appendingPathComponent(rollbackTargetFileName, isDirectory: false)
    }

    private func writeRollbackTarget(_ version: String, in langDir: URL) {
        do {
            try Data(version.utf8).write(to: rollbackTargetURL(in: langDir), options: .atomic)
        } catch {
            logger.error("Failed to record rollback target '\(version, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    private func readRollbackTarget(in langDir: URL) -> String? {
        guard let data = try? Data(contentsOf: rollbackTargetURL(in: langDir)),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    /// Installed version directories: everything that is not the `Current` symlink, a temp link, the
    /// `staging` dir, or a hidden marker file (`.rollback_target` etc.). Sorted numerically ascending.
    private func installedVersions(in langDir: URL) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(atPath: langDir.path)) ?? []
        return contents
            .filter { $0 != "staging" && $0 != "Current" && !$0.starts(with: "Current_temp") && !$0.hasPrefix(".") }
            .sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending })
    }

    // MARK: - Cleanup

    /// Cleans up old versions, keeping the active version plus `retentionPolicy.keepPreviousCount`
    /// versions immediately before it.
    ///
    /// Keeping the immediately-preceding version is load-bearing for two reasons: it is the rollback
    /// target, AND it protects a reader (a `VoiceIntentSession` build) that resolved the *previous*
    /// `Current` moments before the swap — its files are still on disk while it finishes loading.
    /// The hidden `.rollback_target` marker is not a version and is never touched here.
    private func cleanup(language: String, activeVersion: String) throws {
        let langDir = try languageDirectory(for: language)
        let versions = installedVersions(in: langDir)

        guard let activeIndex = versions.firstIndex(of: activeVersion) else { return }

        // Keep the active version and the N versions immediately before it.
        let firstKeptIndex = max(0, activeIndex - retentionPolicy.keepPreviousCount)
        let versionsToKeep = Set(versions[firstKeptIndex...activeIndex])

        for version in versions where !versionsToKeep.contains(version) {
            let urlToDelete = langDir.appendingPathComponent(version, isDirectory: true)
            do {
                try fileManager.removeItem(at: urlToDelete)
            } catch {
                // Non-fatal: a failed prune only wastes disk, it does not corrupt the active pack.
                logger.error("Cleanup could not remove old version '\(version, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }

        // Clean staging directory as well
        let staging = langDir.appendingPathComponent("staging", isDirectory: true)
        if fileManager.fileExists(atPath: staging.path) {
            try? fileManager.removeItem(at: staging)
        }
    }
}

public enum PackStorageError: Error, LocalizedError {
    case versionDirectoryNotFound(String)
    case noActivePackToRollback
    case noPreviousVersionAvailable
    case activationSwapFailed(String)

    public var errorDescription: String? {
        switch self {
        case .versionDirectoryNotFound(let version):
            return "The version directory '\(version)' was not found."
        case .noActivePackToRollback:
            return "There is no active pack to roll back from."
        case .noPreviousVersionAvailable:
            return "There is no previous version available to roll back to."
        case .activationSwapFailed(let reason):
            return "Atomic activation swap failed: \(reason)."
        }
    }
}
