// PipelineTests.swift
// IntentKitCoreTests
//
// The whole pipeline is exercised with zero model files — the payoff of keeping
// IntentKitCore ML-free.

import XCTest
import IntentKitCore
import IntentKitTesting

final class PipelineTests: XCTestCase {

    private func makePipeline(scores: [Double],
                              accept: Double = 0.6,
                              margin: Double = 0.15) -> NLUPipeline {
        NLUPipeline(
            preprocessor: DefaultTextPreprocessor(),
            normalizer: UnicodeTextNormalizer(),
            tokenizer: SimpleWordTokenizer(),
            embedder: MockEmbeddingProvider(),
            backend: MockClassifierBackend(labels: FixtureIntents.all, scores: scores),
            calibrator: SoftmaxCalibrator(),
            contextManager: StatelessContextManager(),
            policy: ThresholdMarginPolicy(acceptThreshold: accept, marginThreshold: margin),
            postProcessor: PassthroughPostProcessor()
        )
    }

    func testConfidentPredictionIsRecognized() async throws {
        let pipeline = makePipeline(scores: [6.0, 0.5, 0.2])   // strong top-1
        let result = try await pipeline.run(NLURequest(text: "turn up the volume"))
        guard case .recognized(let intent, let conf) = result.decision else {
            return XCTFail("expected .recognized, got \(result.decision)")
        }
        XCTAssertEqual(intent, FixtureIntents.volumeUp)
        XCTAssertGreaterThan(conf, 0.6)
    }

    func testCloseTopTwoIsAmbiguous() async throws {
        let pipeline = makePipeline(scores: [2.0, 1.95, 0.1]) // top-2 nearly tied
        let result = try await pipeline.run(NLURequest(text: "change it"))
        guard case .ambiguous(let candidates) = result.decision else {
            return XCTFail("expected .ambiguous, got \(result.decision)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testEmptyInputShortCircuitsToUnknown() async throws {
        let pipeline = makePipeline(scores: [6.0, 0.5, 0.2])
        let result = try await pipeline.run(NLURequest(text: "   "))
        guard case .unknown(let reason) = result.decision else {
            return XCTFail("expected .unknown")
        }
        XCTAssertEqual(reason, .emptyInput)
    }

    func testNearUniformDistributionIsOutOfScope() async throws {
        let pipeline = makePipeline(scores: [1.0, 1.0, 1.0]) // maximal entropy ⇒ OOD
        let result = try await pipeline.run(NLURequest(text: "banana telephone"))
        guard case .unknown(let reason) = result.decision else {
            return XCTFail("expected .unknown")
        }
        XCTAssertEqual(reason, .outOfScope)
    }
}
