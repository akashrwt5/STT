import Foundation

public protocol PackStorageControlling {
    func stagingDirectory(for language: String, clean: Bool) throws -> URL
    func currentPack(for language: String) -> URL?
    func hasActivePack(for language: String) -> Bool
    func commitStagingAndActivate(version: String, for language: String) throws
    func activate(version: String, for language: String) throws
    func rollback(for language: String) throws
}

/// Manages the on-disk storage layout, atomic activation, and rollback for NLU packs.
/// Enforces the filesystem as the single source of truth using atomic symbolic links.
public final class PackStorageController: PackStorageControlling {
    /// The base directory provided by the Host Application (e.g., Application Support or an App Group container).
    public let baseStorageURL: URL
    
    /// The root directory for all VoiceIntentKit data: `{baseStorageURL}/VoiceIntentKit`
    private var rootURL: URL {
        baseStorageURL.appendingPathComponent("VoiceIntentKit", isDirectory: true)
    }
    
    /// The directory containing all downloaded language packs: `{rootURL}/Packs`
    private var packsURL: URL {
        rootURL.appendingPathComponent("Packs", isDirectory: true)
    }
    
    private let fileManager: FileManager
    
    /// Initializes the storage controller and ensures the root directory structure exists.
    public init(baseStorageURL: URL, fileManager: FileManager = .default) throws {
        self.baseStorageURL = baseStorageURL
        self.fileManager = fileManager
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
    
    /// Atomically swaps the `Current` symbolic link to point to the new version.
    public func activate(version: String, for language: String) throws {
        let langDir = try languageDirectory(for: language)
        let newVersionURL = langDir.appendingPathComponent(version, isDirectory: true)
        let currentLinkURL = langDir.appendingPathComponent("Current", isDirectory: false)
        
        guard fileManager.fileExists(atPath: newVersionURL.path) else {
            throw PackStorageError.versionDirectoryNotFound(version)
        }
        
        // Atomic swap: create a temporary symlink and then move it over the existing `Current` link.
        let tempLinkURL = langDir.appendingPathComponent("Current_temp_\(UUID().uuidString)", isDirectory: false)
        
        // Create a relative symlink (e.g., pointing to "1.0.36")
        try fileManager.createSymbolicLink(atPath: tempLinkURL.path, withDestinationPath: version)
        
        do {
            // Safely remove the existing symlink (whether valid or broken) to avoid Apple's replaceItemAt resolving the target.
            _ = try? fileManager.removeItem(at: currentLinkURL)
            try fileManager.moveItem(at: tempLinkURL, to: currentLinkURL)
        } catch {
            // Cleanup temp link if swap failed
            try? fileManager.removeItem(at: tempLinkURL)
            throw error
        }
        
        // Run cleanup policy after successful activation
        try cleanup(language: language, activeVersion: version)
    }
    
    /// Rolls back to the previously installed version, if one exists.
    public func rollback(for language: String) throws {
        let langDir = try languageDirectory(for: language)
        let currentLinkURL = langDir.appendingPathComponent("Current", isDirectory: false)
        
        guard fileManager.fileExists(atPath: currentLinkURL.path) else {
            throw PackStorageError.noActivePackToRollback
        }
        
        let currentVersionPath = try fileManager.destinationOfSymbolicLink(atPath: currentLinkURL.path)
        
        // Find all installed versions (directories in the language folder, excluding 'staging' and 'Current')
        let contents = try fileManager.contentsOfDirectory(atPath: langDir.path)
        let versions = contents.filter { $0 != "staging" && $0 != "Current" && !$0.starts(with: "Current_temp") }
            .sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending })
        
        guard let previousVersion = versions.filter({ $0 != currentVersionPath }).last else {
            throw PackStorageError.noPreviousVersionAvailable
        }
        
        // Atomically activate the previous version
        try activate(version: previousVersion, for: language)
    }
    
    // MARK: - Cleanup
    
    /// Cleans up old versions, keeping only the active version and the immediately preceding version.
    private func cleanup(language: String, activeVersion: String) throws {
        let langDir = try languageDirectory(for: language)
        let contents = try fileManager.contentsOfDirectory(atPath: langDir.path)
        
        // Filter out symlinks and staging
        let versions = contents.filter { $0 != "staging" && $0 != "Current" && !$0.starts(with: "Current_temp") }
            .sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending })
        
        guard let activeIndex = versions.firstIndex(of: activeVersion) else { return }
        
        // Keep active version and the one immediately before it
        let versionsToKeep = [activeVersion, activeIndex > 0 ? versions[activeIndex - 1] : nil].compactMap { $0 }
        
        for version in versions {
            if !versionsToKeep.contains(version) {
                let urlToDelete = langDir.appendingPathComponent(version, isDirectory: true)
                try? fileManager.removeItem(at: urlToDelete)
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
    
    public var errorDescription: String? {
        switch self {
        case .versionDirectoryNotFound(let version):
            return "The version directory '\(version)' was not found."
        case .noActivePackToRollback:
            return "There is no active pack to roll back from."
        case .noPreviousVersionAvailable:
            return "There is no previous version available to roll back to."
        }
    }
}
