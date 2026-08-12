import XCTest
@testable import VoiceIntentKit

/// Real-filesystem tests for the storage layer's safety-critical behaviour: atomic activation,
/// C7 known-good rollback, and retention. No crypto or engine needed — this exercises the on-disk
/// state machine directly against a temporary directory.
final class PackStorageControllerTests: XCTestCase {

    var base: URL!
    var storage: PackStorageController!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("PackStore_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        storage = try PackStorageController(baseStorageURL: base)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    /// Path of an installed version directory (mirrors the controller's documented layout).
    private func versionDir(_ version: String, _ lang: String = "en") -> URL {
        base.appendingPathComponent("VoiceIntentKit/Packs/\(lang)/\(version)", isDirectory: true)
    }

    /// Installs a version through the real staging → commit → activate flow.
    private func install(_ version: String, lang: String = "en") throws {
        let staging = try storage.stagingDirectory(for: lang, clean: true)
        try Data("model-\(version)".utf8).write(to: staging.appendingPathComponent("model.bin"))
        try storage.commitStagingAndActivate(version: version, for: lang)
    }

    func testActivateResolvesCurrentPack() throws {
        try install("1.0.0")
        let current = storage.currentPack(for: "en")
        XCTAssertEqual(current?.lastPathComponent, "1.0.0")
        XCTAssertTrue(storage.hasActivePack(for: "en"))
    }

    func testActivationIsAtomicOverExistingCurrent() throws {
        try install("1.0.0")
        try install("1.0.1")
        // Current always resolves — never a missing link after a swap.
        XCTAssertEqual(storage.currentPack(for: "en")?.lastPathComponent, "1.0.1")
    }

    /// C7: rollback must return to the version that was active before the current one — the recorded
    /// known-good target — not merely "the highest other version".
    func testRollbackReturnsToKnownGoodPrevious() throws {
        try install("1.0.0")
        try install("1.0.1")
        try storage.rollback(for: "en")
        XCTAssertEqual(storage.currentPack(for: "en")?.lastPathComponent, "1.0.0",
                       "Rollback should land on the previously-active known-good version")
    }

    /// Retention keeps the active version plus one previous; older versions are pruned.
    func testRetentionKeepsActiveAndPrevious() throws {
        try install("1.0.0")
        try install("1.0.1")
        try install("1.0.2")

        XCTAssertTrue(FileManager.default.fileExists(atPath: versionDir("1.0.2").path), "active kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionDir("1.0.1").path), "previous kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: versionDir("1.0.0").path), "older pruned")
    }

    func testRollbackWithNoPreviousThrows() throws {
        try install("1.0.0")
        XCTAssertThrowsError(try storage.rollback(for: "en")) { error in
            guard case PackStorageError.noPreviousVersionAvailable = error else {
                return XCTFail("Expected noPreviousVersionAvailable, got \(error)")
            }
        }
    }
}
