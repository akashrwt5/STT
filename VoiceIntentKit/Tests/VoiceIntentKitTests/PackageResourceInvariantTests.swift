// PackageResourceInvariantTests.swift
// VoiceIntentKitTests
//
// The zero-data guarantee, asserted instead of assumed.
//
// The guarantee is structural first: `Package.swift` declares no `resources:` block
// for the `VoiceIntentKit` target, so SwiftPM does not even synthesise a
// `Bundle.module` for it and there is nothing for a model or a lexicon to hide in.
//
// This test exists because that structure is one line away from being spent. A
// `PrivacyInfo.xcprivacy` was added here and removed again within a day; the moment
// any resource is declared, `Bundle.module` appears and a JSON file becomes a
// plausible next commit. The check below fails on the FILE, before anyone gets as
// far as declaring it — and names the file in the failure.

import Foundation
import XCTest

final class PackageResourceInvariantTests: XCTestCase {

    /// `Sources/VoiceIntentKit/` contains Swift sources and nothing else.
    func testLibraryTargetShipsNoDataFiles() throws {
        let target = Self.librarySourcesDirectory
        let manager = FileManager.default

        let files = try manager
            .subpathsOfDirectory(atPath: target.path)
            .filter { !$0.hasSuffix(".DS_Store") }
            .filter { path in
                var isDirectory: ObjCBool = false
                manager.fileExists(atPath: target.appendingPathComponent(path).path,
                                   isDirectory: &isDirectory)
                return !isDirectory.boolValue
            }

        XCTAssertFalse(files.isEmpty, "Walked the target and found no sources — the path is wrong, not the target empty.")

        let unexpected = files.filter { !$0.hasSuffix(".swift") }
        XCTAssertTrue(
            unexpected.isEmpty,
            """
            The VoiceIntentKit target must ship no data — every byte it classifies \
            with comes from a host-supplied, verified pack. Unexpected file(s) under \
            Sources/VoiceIntentKit/: \(unexpected.sorted()). A model, schema, lexicon \
            or entity table belongs in a pack, not in the binary.
            """)
    }

    /// Reached by walking `#filePath`, the same idiom `PackTestSupport` uses: the test
    /// target cannot see the library's directory any other way, and adding a dependency
    /// just to find a folder would be worse than walking to it.
    private static var librarySourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VoiceIntentKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // VoiceIntentKit (package root)
            .appendingPathComponent("Sources")
            .appendingPathComponent("VoiceIntentKit")
    }
}
