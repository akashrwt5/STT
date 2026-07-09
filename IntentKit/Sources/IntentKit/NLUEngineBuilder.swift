// NLUEngineBuilder.swift
// IntentKit
//
// Composition root for the 10% of apps that need full control: swap any stage,
// backend, policy, or context manager. Everything defaults to a sensible value so
// callers override only what they care about (Open/Closed at the API surface).

import Foundation
import IntentKitCore
import IntentKitCoreML

public struct NLUEngineBuilder {

    private var preprocessor: any TextPreprocessor = DefaultTextPreprocessor()
    private var normalizer: any TextNormalizer = UnicodeTextNormalizer()
    private var tokenizer: any Tokenizer = NLWordTokenizer()
    private var embedder: any EmbeddingProvider = NLEmbeddingProvider()
    private var calibrator: any ConfidenceCalibrator = SoftmaxCalibrator()
    private var contextManager: any ContextManager = StatelessContextManager()
    private var policy: any DecisionPolicy = ThresholdMarginPolicy()
    private var postProcessor: any IntentPostProcessor = PassthroughPostProcessor()
    private var backend: (any IntentClassifierBackend)?
    private var locale: Locale = .current

    public init() {}

    public func backend(_ b: any IntentClassifierBackend) -> Self { var c = self; c.backend = b; return c }
    public func embedder(_ e: any EmbeddingProvider) -> Self { var c = self; c.embedder = e; return c }
    public func tokenizer(_ t: any Tokenizer) -> Self { var c = self; c.tokenizer = t; return c }
    public func normalizer(_ n: any TextNormalizer) -> Self { var c = self; c.normalizer = n; return c }
    public func calibrator(_ cal: any ConfidenceCalibrator) -> Self { var c = self; c.calibrator = cal; return c }
    public func policy(_ p: any DecisionPolicy) -> Self { var c = self; c.policy = p; return c }
    public func contextManager(_ m: any ContextManager) -> Self { var c = self; c.contextManager = m; return c }
    public func postProcessor(_ p: any IntentPostProcessor) -> Self { var c = self; c.postProcessor = p; return c }
    public func locale(_ l: Locale) -> Self { var c = self; c.locale = l; return c }

    public func build() throws -> NLUEngine {
        guard let backend else { throw IntentKitError.modelNotFound("no backend configured") }
        let pipeline = NLUPipeline(
            preprocessor: preprocessor, normalizer: normalizer, tokenizer: tokenizer,
            embedder: embedder, backend: backend, calibrator: calibrator,
            contextManager: contextManager, policy: policy, postProcessor: postProcessor
        )
        return NLUEngine(pipeline: pipeline, locale: locale)
    }
}
