// PackLoadingTests.swift
// VoiceAIKitTests
//
// The loader's contract: a pack either loads completely or throws a named
// error. It never partially loads, and it never falls back.
//
// The negative cases matter more than the positive one. The code this replaces
// degraded to English on any failure — `LocalizationLoader` caught every error
// and returned the English schema, and `NLULexicon` decoded with
// `try? … ?? []`. A corrupt French pack produced a working English session and
// green tests. Each test below asserts a THROW; a silent success is the
// regression.

import XCTest
@testable import VoiceAIKit

final class PackLoadingTests: XCTestCase {

    // MARK: - Happy path

    func testVendoredPackLoads() throws {
        let pack = try PackTestSupport.loadPack()

        XCTAssertEqual(pack.language, "en")
        XCTAssertFalse(pack.intents.isEmpty)
        XCTAssertFalse(pack.responses.isEmpty)
        XCTAssertFalse(pack.classifier.labels.isEmpty)
        XCTAssertEqual(pack.manifest.formatMajor, VIKSupportedFormatMajor)
    }

    /// The join proves referential integrity, so nothing downstream has to
    /// re-check it. If this fails the pack is internally inconsistent.
    func testEveryReferencedKeyResolves() throws {
        let pack = try PackTestSupport.loadPack()

        for (intent, workflow) in pack.intents {
            if let completion = workflow.completion {
                XCTAssertNotNil(pack.responses[completion.response],
                                "\(intent) → dangling response \(completion.response)")
                XCTAssertNotNil(pack.actionOwners[completion.action],
                                "\(intent) → dangling action \(completion.action)")
            }
            for slot in workflow.slots {
                XCTAssertNotNil(pack.responses[slot.prompt],
                                "\(intent).\(slot.name) → dangling prompt \(slot.prompt)")
                XCTAssertTrue(pack.entities[slot.entity] != nil
                                || pack.dynamicEntities.contains(slot.entity),
                              "\(intent).\(slot.name) → unknown entity \(slot.entity)")
            }
        }
    }

    /// The classifier's label space and the dialog schema must come from the
    /// same build. A published pack once declared 2 labels beside a 57-class
    /// model, so every prediction was mislabelled.
    func testLabelSpaceMatchesIntentSet() throws {
        let pack = try PackTestSupport.loadPack()
        XCTAssertEqual(Set(pack.classifier.labels), pack.intentIDs)
        if let dim = pack.cascade.tfidfOutputDim {
            XCTAssertEqual(dim, pack.classifier.labels.count)
        }
    }

    /// The pack decides which stages run, not host configuration — its report
    /// card was measured under those settings.
    func testCascadeGatesStages() throws {
        let pack = try PackTestSupport.loadPack()
        XCTAssertTrue(pack.stageEnabled(.keyword))
        XCTAssertTrue(pack.stageEnabled(.tfidf))
        XCTAssertFalse(pack.stageEnabled(.semantic),
                       "en packs disable semantic rescue; a host must not override it")
    }

    /// Sections added after the first packs shipped.
    func testGuardsArePresentAndTheConfirmBandIsConsistent() throws {
        let pack = try PackTestSupport.loadPack()

        let helpMarker = try XCTUnwrap(pack.guards.helpMarker,
                                       "runtime/guards.json missing — help-phrased utterances will fire commands")
        XCTAssertFalse(helpMarker.pairs.isEmpty)
        for (from, to) in helpMarker.pairs {
            XCTAssertTrue(pack.intentIDs.contains(from), "guard source \(from) not in the pack")
            XCTAssertTrue(pack.intentIDs.contains(to), "guard target \(to) not in the pack")
        }

        // The band is GONE from pack-en, and deliberately: the compiler moved to one
        // fire threshold with no confidence-driven confirmation. So the assertion is
        // the consistency rule rather than the field's presence — a pack may omit the
        // band only while no intent asks for `when_ambiguous`, because a runtime that
        // meets one without the other can only degrade it to `never`, and the intent
        // then acts without confirming.
        let ambiguous = pack.intents.keys
            .filter { pack.confirmationPolicy(for: $0) == .whenAmbiguous }
            .sorted()
        if let band = pack.uncertainConfirmBand {
            XCTAssertLessThan(band.floor, band.ceiling, "an inverted band gates nothing")
        } else {
            XCTAssertTrue(ambiguous.isEmpty, """
                No uncertain_confirm_below/_floor, but \(ambiguous) request when_ambiguous — \
                those intents will act without confirming.
                """)
        }
    }

    /// The variant triple: head, vocabulary and temperature must agree.
    func testFullVariantBindsItsOwnWeightsAndTemperature() throws {
        let pruned = try PackTestSupport.loadPack(variant: .pruned)
        let full = try PackTestSupport.loadPack(variant: .full)

        XCTAssertNotEqual(pruned.classifier.temperature, full.classifier.temperature,
                          "each head has its own fitted T; sharing one silently shifts every gate")
        XCTAssertNotEqual(pruned.classifier.weightsURL, full.classifier.weightsURL)
        XCTAssertEqual(full.classifier.variant, .full)
    }

    // MARK: - Negative paths
    //
    // Each mutates a copy of the pack and asserts a specific throw.

    func testTamperedFileIsRejected() throws {
        try withMutatedPack({ root in
            let target = root.appendingPathComponent("runtime/policies.json")
            var data = try Data(contentsOf: target)
            data.append(0x20)                     // one trailing space
            try data.write(to: target)
        }, expecting: { if case .fileDigestMismatch = $0 { return true }; return false },
           named: "fileDigestMismatch")
    }

    func testBrokenChecksumsRootIsRejected() throws {
        try withMutatedPack({ root in
            let target = root.appendingPathComponent("bundle.json")
            var object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: target)) as? [String: Any] ?? [:]
            object["checksums_root"] = String(repeating: "0", count: 64)
            try JSONSerialization.data(withJSONObject: object).write(to: target)
        }, expecting: { if case .checksumsRootMismatch = $0 { return true }; return false },
           named: "checksumsRootMismatch")
    }

    func testMissingCoveredFileIsRejected() throws {
        try withMutatedPack({ root in
            try FileManager.default.removeItem(at: root.appendingPathComponent("runtime/guards.json"))
        }, expecting: { if case .integrityFileMissing = $0 { return true }; return false },
           named: "integrityFileMissing")
    }

    /// An unsigned file cannot affect anything signed, but its presence means
    /// the tree is not what was published.
    func testInjectedUnsignedFileIsRejected() throws {
        try withMutatedPack({ root in
            try Data("{}".utf8).write(to: root.appendingPathComponent("runtime/injected.json"))
        }, expecting: { if case .unsignedFilesPresent = $0 { return true }; return false },
           named: "unsignedFilesPresent")
    }

    func testUnknownLanguageIsRejected() throws {
        let root = try PackTestSupport.packRoot()
        XCTAssertThrowsError(
            try BundleDataLoader.load(packAt: root, language: "fr",
                                      trust: PackTestSupport.trust)
        ) { error in
            guard case VoiceIntentError.languageUnavailable(let requested, _) = error else {
                return XCTFail("expected languageUnavailable, got \(error)")
            }
            XCTAssertEqual(requested, "fr")
        }
    }

    func testMissingPackIsRejected() {
        let nowhere = URL(fileURLWithPath: "/tmp/voiceaikit-does-not-exist")
        XCTAssertThrowsError(
            try BundleDataLoader.load(packAt: nowhere, trust: PackTestSupport.trust)
        ) { error in
            guard case VoiceIntentError.packNotFound = error else {
                return XCTFail("expected packNotFound, got \(error)")
            }
        }
    }

    /// Packs through 1.0.28 ship no full-vocabulary weights. Asking for `.full`
    /// there must fail at LOAD with a named path, not at the first inference
    /// with a shape mismatch.
    func testFullVariantWithoutItsWeightsFailsAtLoad() throws {
        try withMutatedPack({ root in
            let weights = root.appendingPathComponent(
                "models/intent/en/intent_classifier_weights_full.json")
            if FileManager.default.fileExists(atPath: weights.path) {
                try FileManager.default.removeItem(at: weights)
            }
        }, expecting: {
            // The weights are covered by the manifest, so removing them trips
            // integrity BEFORE the variant resolver ever runs. Either is a
            // correct refusal; the point is that it fails at load rather than
            // at the first inference with a shape mismatch.
            switch $0 {
            case .declaredArtifactMissing, .integrityFileMissing: return true
            default: return false
            }
        }, named: "declaredArtifactMissing or integrityFileMissing", variant: .full)
    }

    /// A dev-signed pack must be refused by a production trust policy
    /// (ADR-005 Part 11).
    func testDevelopmentPackRefusedUnderStrictTrust() throws {
        let root = try PackTestSupport.packRoot()
        let strict = PackTrustPolicy(publicKeys: [:],
                                     refusesDevelopmentPacks: true,
                                     skipsSignatureVerification: true)
        XCTAssertThrowsError(try BundleDataLoader.load(packAt: root, trust: strict)) { error in
            guard case VoiceIntentError.untrustedPack = error else {
                return XCTFail("expected untrustedPack, got \(error)")
            }
        }
    }

    /// With verification ON and no key registered, the pack cannot be trusted.
    func testUnknownSigningKeyIsRejected() throws {
        let root = try PackTestSupport.packRoot()
        let verifying = PackTrustPolicy(publicKeys: [:],
                                        refusesDevelopmentPacks: false,
                                        skipsSignatureVerification: false)
        XCTAssertThrowsError(try BundleDataLoader.load(packAt: root, trust: verifying)) { error in
            guard case VoiceIntentError.signingKeyUnknown = error else {
                return XCTFail("expected signingKeyUnknown, got \(error)")
            }
        }
    }

    // MARK: - Helper

    /// Copy the pack, break it, and assert the loader refuses it with the right
    /// error.
    ///
    /// The predicate pattern-matches the ENUM CASE. An earlier version compared
    /// `String(describing: error)` against a case name, which silently never
    /// matched: `VoiceIntentError` conforms to `CustomStringConvertible`, so
    /// `String(describing:)` returns the human-readable message
    /// ("Digest mismatch for …"), not "fileDigestMismatch". Five tests failed
    /// while the loader was behaving perfectly — the assertions were wrong, not
    /// the code.
    private func withMutatedPack(_ mutate: (URL) throws -> Void,
                                 expecting matches: (VoiceIntentError) -> Bool,
                                 named expectation: String,
                                 variant: ClassifierVariant = .full,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) throws {
        let source = try PackTestSupport.packRoot()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vik-pack-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        try mutate(scratch)

        do {
            _ = try BundleDataLoader.load(packAt: scratch, variant: variant,
                                          trust: PackTestSupport.trust)
            XCTFail("pack loaded despite being broken — expected \(expectation)",
                    file: file, line: line)
        } catch let error as VoiceIntentError {
            XCTAssertTrue(matches(error),
                          "expected \(expectation), got \(error)", file: file, line: line)
        }
    }
}
