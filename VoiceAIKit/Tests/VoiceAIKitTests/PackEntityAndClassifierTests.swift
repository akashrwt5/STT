// PackEntityAndClassifierTests.swift
// VoiceAIKitTests
//
// Entity resolution and Stage-2 classification, against the same reference the
// model was trained by.

import XCTest
@testable import VoiceAIKit

// MARK: - Entities

final class PackEntityExtractorTests: XCTestCase {

    private var extractor: PackEntityExtractor!
    private var reference: PackTestSupport.Reference!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let pack = try PackTestSupport.loadPack()
        extractor = PackEntityExtractor(pack: pack)
        reference = try PackTestSupport.reference()
    }

    func testEveryReferenceCaseResolvesIdentically() throws {
        var failures: [String] = []

        for expected in reference.entities {
            let actual = extractor.extract(expected.entity, from: expected.text)

            guard let expectedValue = expected.value else {
                if let actual {
                    failures.append("""
                        \(expected.text.debugDescription): reference resolved NOTHING, \
                        got \(actual.value) at \(actual.confidence)
                        """)
                }
                continue
            }
            guard let actual else {
                failures.append("\(expected.text.debugDescription): expected \(expectedValue), got nil")
                continue
            }
            if actual.value != expectedValue {
                failures.append("""
                    \(expected.text.debugDescription): expected \(expectedValue), got \(actual.value)
                    """)
            }
            if abs(actual.confidence - expected.confidence) > 0.005 {
                failures.append("""
                    \(expected.text.debugDescription): confidence expected \
                    \(expected.confidence), got \(actual.confidence)
                    """)
            }
        }

        XCTAssertTrue(failures.isEmpty, """
            \(failures.count) divergence(s) from the Python reference:
            \(failures.joined(separator: "\n"))
            """)
    }

    /// The reason the stopword list exists. The memory "three" is two edits from
    /// "the", so without the guard an off-topic sentence fuzzy-fills the slot.
    func testFunctionWordsAreNeverTypos() throws {
        XCTAssertNil(extractor.extract("memory", from: "who is the prime minister of india"),
                     "'the' must not fuzzy-match the memory 'three'")
    }

    /// Fuzzy is for answers to an explicit prompt. Scanning a whole utterance
    /// with it on is a wrong-action risk.
    func testFuzzyCanBeDisabledForSpeculativeScans() throws {
        let withFuzzy = extractor.extract("memory", from: "switch to restraunt", allowFuzzy: true)
        let without = extractor.extract("memory", from: "switch to restraunt", allowFuzzy: false)

        XCTAssertNotNil(withFuzzy, "a typo should resolve when fuzzy is allowed")
        XCTAssertNil(without, "the same typo must not resolve when it is not")
    }

    func testConfidenceTiersAreDistinct() throws {
        let exact = try XCTUnwrap(extractor.extract("memory", from: "switch to restaurant"))
        let fuzzy = try XCTUnwrap(extractor.extract("memory", from: "switch to restraunt"))

        XCTAssertEqual(exact.confidence, 1.00, accuracy: 0.001)
        XCTAssertFalse(exact.isFuzzy)
        XCTAssertTrue(fuzzy.isFuzzy)
        XCTAssertLessThanOrEqual(fuzzy.confidence, 0.90)
        XCTAssertGreaterThanOrEqual(fuzzy.confidence, 0.60)
    }

    /// VIK-003: the flag was dropped in the join, silently disabling fuzzy for
    /// every entity. A mistyped memory name simply stopped filling the slot.
    func testFuzzyFlagSurvivesThePackJoin() throws {
        let pack = try PackTestSupport.loadPack()
        XCTAssertTrue(pack.fuzzyEntities.contains("memory"),
                      "memory is fuzzy in the pack; losing the flag disables approximate matching")
        XCTAssertFalse(pack.fuzzyEntities.contains("recurrence"),
                       "recurrence is not fuzzy — the flag must be read, not assumed")
    }

    func testDynamicEntitiesAreNotGazetteerMatched() throws {
        let pack = try PackTestSupport.loadPack()
        XCTAssertTrue(pack.dynamicEntities.contains("sys.date_time"),
                      "sys.date_time is resolved by the datetime parser, not a value list")
    }
}

// MARK: - Classifier

final class PackIntentClassifierTests: XCTestCase {

    private var classifier: PackIntentClassifier!
    private var pack: ResolvedPack!

    override func setUpWithError() throws {
        try super.setUpWithError()
        pack = try PackTestSupport.loadPack()
        classifier = try PackIntentClassifier(artifacts: pack.classifier)
    }

    /// The labels are the ones the model actually trains on, checked against the
    /// pack's own label set first. They moved once already — `device.volume.increase`
    /// became `Cmd.VolumeIncrease` in the compiler's `Cmd.*` rename — and because
    /// this suite was silently skipping, the rename surfaced as four flat mismatches
    /// that read like an accuracy regression. It was not: the model classified all
    /// four utterances correctly under the new names.
    func testConfidentCommandsClassifyAndClearTheGate() async throws {
        let cases: [(String, String)] = [
            ("turn up the volume", "Cmd.VolumeIncrease"),
            ("what is my battery level", "Cmd.BatteryLevel"),
            ("remind me to call mom at 6 pm", "reminders.add"),
            ("find my phone", "Cmd.FindMyPhone"),
        ]
        PackTestSupport.assertLabelsExist(cases.map(\.1), in: pack)
        for (utterance, expected) in cases {
            let prediction = await classifier.classify(utterance)
            XCTAssertEqual(prediction.intent, expected, utterance)
            XCTAssertTrue(prediction.passesGate,
                          "\(utterance) scored \(prediction.confidence), below the pack's gate")
            XCTAssertFalse(prediction.isVacuous)
        }
    }

    /// The help-marker guard's reason for existing: a question ABOUT a command
    /// must not fire the command.
    func testHelpPhrasedUtteranceDoesNotFireTheCommand() async throws {
        let prediction = await classifier.classify("how do i turn up the volume")
        XCTAssertNotEqual(prediction.intent, "Cmd.VolumeIncrease",
                          "asking how to change the volume must not change the volume")
    }

    /// VIK-011: with no feature matched every logit collapses to its intercept,
    /// so argmax is a fixed label and softmax over it can still clear 0.70.
    func testUtteranceWithNoKnownFeaturesIsVacuousAndFailsTheGate() async throws {
        let prediction = await classifier.classify("asdfgh qwerty zxcvbn")
        XCTAssertTrue(prediction.isVacuous, "nothing matched the vocabulary")
        XCTAssertFalse(prediction.passesGate, "a vacuous prediction must never clear the gate")
    }

    /// VIK-002: sklearn drops 1-character tokens BEFORE forming bigrams, so
    /// "set a reminder" trains on `set reminder`. Keeping the "a" produces
    /// `set a` + `a reminder` and the trained feature is never generated.
    /// VIK-054. The out-of-vocabulary ratio, against the pack's real vocabulary.
    ///
    /// Pins the numbers the guard was fitted on. The first and third case have
    /// the SAME ratio and opposite correct answers — "john" is an entity value,
    /// "paper" puts the utterance out of scope — which is the whole reason the
    /// guard needs `oov_bypass` as well as `oov_reject`, and the reason this test
    /// asserts the ratio rather than the verdict.
    ///
    /// Measured identically by the reference `IntentClassifier.oov_ratio`, which
    /// tokenises with `(?u)\b\w\w+\b` and counts against the UNIGRAM vocabulary.
    func testOutOfVocabularyRatioMatchesTheReference() async throws {
        let cases: [(String, Double)] = [
            ("send a message to john", 1.0 / 4.0),   // a real command
            ("stream from netflix",    1.0 / 3.0),   // a real command
            ("help me find a paper",   1.0 / 4.0),   // out of scope
            ("increase the volume",    0.0),
        ]
        for (utterance, expected) in cases {
            let ratio = await classifier.oovRatio(utterance)
            XCTAssertEqual(ratio, expected, accuracy: 1e-9,
                           "oov ratio changed for '\(utterance)'")
        }
    }

    /// The guard asks "can the featurizer represent this WORD?", so a bigram is
    /// not an answer to it and must not be counted as vocabulary.
    func testOnlyUnigramsCountAsKnownVocabulary() throws {
        let vectorizer = PackTFIDFVectorizer(
            vocabulary: ["set": 0, "reminder": 1, "set reminder": 2],
            idf: [1, 1, 1])
        XCTAssertEqual(vectorizer.unigrams, ["set", "reminder"])
        // "tomorrow" is unknown; "set" and "reminder" are not.
        XCTAssertEqual(vectorizer.oovRatio("set reminder tomorrow"), 1.0 / 3.0, accuracy: 1e-9)
        // No vocabulary at all disables the guard rather than refusing everything.
        XCTAssertEqual(PackTFIDFVectorizer(vocabulary: [:], idf: []).oovRatio("anything"), 0)
    }

    func testTokenizerMatchesTheTrainer() throws {
        let vectorizer = PackTFIDFVectorizer(
            vocabulary: ["set": 0, "reminder": 1, "set reminder": 2],
            idf: [1, 1, 1])

        let features = vectorizer.features("set a reminder")
        XCTAssertTrue(features.contains("set reminder"),
                      "the 1-character token must be dropped before bigrams are formed")
        XCTAssertFalse(features.contains("set a"))
        XCTAssertFalse(features.contains("a reminder"))
    }

    /// Temperature scaling is rank-preserving, so it changes confidence but
    /// never which intent wins.
    func testTemperatureComesFromTheDeviceCalibration() throws {
        XCTAssertGreaterThan(pack.classifier.temperature, 0)
        XCTAssertNotEqual(pack.classifier.temperature, 1.0,
                          "T=1.0 means the pack's calibration was not applied")
    }

    func testWarmUpIsIdempotent() async throws {
        await classifier.warmUp()
        await classifier.warmUp()
        let prediction = await classifier.classify("turn up the volume")
        XCTAssertEqual(prediction.intent, "Cmd.VolumeIncrease")
    }
}
