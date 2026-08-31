// PackIdentityTests.swift
// VoiceAIKitTests
//
// Exercised against the SHIPPING seed pack, not a fixture — the point of identity is
// that it describes real bytes, and a hand-written fixture would agree with whatever
// the code does.

import Foundation
import XCTest
@testable import VoiceAIKit

final class PackIdentityTests: XCTestCase {

    func testVerifyReturnsTheIdentityTheSeedPackDeclares() throws {
        let root = try PackTestSupport.packRoot()
        let identity = try VoiceIntentPack.verify(
            at: root, language: "en", trust: PackTestSupport.trust)

        XCTAssertFalse(identity.bundleID.isEmpty)
        XCTAssertFalse(identity.checksumRoot.isEmpty)
        XCTAssertFalse(identity.keyID.isEmpty)
        XCTAssertFalse(identity.channel.isEmpty)
        XCTAssertFalse(identity.compilerVersion.isEmpty)
        XCTAssertTrue(identity.languages.contains("en"),
                      "The en seed pack must declare 'en'; declared: \(identity.languages)")

        // 64 hex characters — a sha256 root, not a truncation of one.
        XCTAssertEqual(identity.checksumRoot.count, 64)
    }

    /// `version` is read, never derived.
    ///
    /// `nlu_compiler` emits both from one variable, so they agree by construction in
    /// real output. They differ in the vendored seed pack only because `1.0.35` was
    /// hardcoded there for OTA testing — which is exactly the case that proves the
    /// point: anything parsing the version out of the bundle id would report a
    /// different answer than the OTA path for the same pack.
    func testVersionIsReadFromTheManifestNotParsedFromTheBundleID() throws {
        let root = try PackTestSupport.packRoot()
        let identity = try VoiceIntentPack.verify(at: root, trust: PackTestSupport.trust)

        let bundleData = try Data(contentsOf: root.appendingPathComponent("bundle.json"))
        let raw = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bundleData) as? [String: Any])

        XCTAssertEqual(identity.version, try XCTUnwrap(raw["version"] as? String))
        XCTAssertEqual(identity.bundleID, raw["bundle_id"] as? String)
        XCTAssertEqual(identity.checksumRoot, raw["checksums_root"] as? String)
    }

    /// A pack that verifies perfectly but does not speak the language you asked for is
    /// not a pack you can use, so `verify` refuses it here rather than letting the
    /// caller discover it at `start()`.
    func testVerifyRefusesALanguageThePackDoesNotCarry() throws {
        let root = try PackTestSupport.packRoot()
        XCTAssertThrowsError(
            try VoiceIntentPack.verify(at: root, language: "xx", trust: PackTestSupport.trust)
        ) { error in
            guard case VoiceIntentError.languageUnavailable(let requested, _) = error else {
                return XCTFail("expected .languageUnavailable, got \(error)")
            }
            XCTAssertEqual(requested, "xx")
        }
    }

    func testVerifyReportsAMissingPackRatherThanCrashing() {
        let missing = URL(fileURLWithPath: "/tmp/voiceaikit-no-such-pack-\(UUID().uuidString)")
        XCTAssertThrowsError(
            try VoiceIntentPack.verify(at: missing, trust: PackTestSupport.trust)
        ) { error in
            guard case VoiceIntentError.packNotFound = error else {
                return XCTFail("expected .packNotFound, got \(error)")
            }
        }
    }
}
