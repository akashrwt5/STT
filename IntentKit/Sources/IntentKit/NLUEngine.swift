// NLUEngine.swift
// IntentKit
//
// The public entry point. An `actor` — NOT @MainActor — so inference runs off the
// main thread (the deliberate divergence from the STT module, whose @MainActor
// isolation is dictated by AVAudioEngine). The actor also serializes access to the
// single shared Core ML model instance.

@_exported import IntentKitCore
import Foundation
import IntentKitCoreML

public actor NLUEngine {

    private let pipeline: NLUPipeline
    private let defaultLocale: Locale

    /// One-line initializer for the common Core ML case. `async throws` so model
    /// loading, label-schema validation, and warm-up happen before first use.
    public init(configuration config: IntentKitConfiguration, locale: Locale = .current) async throws {
        let modelURL = try Self.resolveModelURL(config.model)
        let backend = try CoreMLClassifierBackend(modelURL: modelURL, labels: config.labels)

        self.pipeline = NLUPipeline(
            preprocessor: DefaultTextPreprocessor(),
            normalizer: UnicodeTextNormalizer(),
            tokenizer: NLWordTokenizer(),
            embedder: NLEmbeddingProvider(),
            backend: backend,
            calibrator: SoftmaxCalibrator(temperature: config.softmaxTemperature),
            contextManager: StatelessContextManager(),
            policy: ThresholdMarginPolicy(
                acceptThreshold: config.acceptThreshold,
                marginThreshold: config.marginThreshold,
                maxEntropyRatio: config.maxEntropyRatio
            ),
            postProcessor: PassthroughPostProcessor()
        )
        self.defaultLocale = locale

        // Warm up so the first REAL classification doesn't pay the compile cost.
        _ = try? await pipeline.run(NLURequest(text: "warm up", locale: locale))
    }

    /// Full-control initializer: inject a completely custom pipeline (any backends,
    /// stages, and policies). Used by `NLUEngineBuilder` and advanced consumers.
    public init(pipeline: NLUPipeline, locale: Locale = .current) {
        self.pipeline = pipeline
        self.defaultLocale = locale
    }

    // MARK: - Public API

    /// Classify a single utterance. One call runs the entire pipeline.
    public func classify(_ text: String, context: ConversationContext = .empty) async throws -> IntentResult {
        try await pipeline.run(NLURequest(text: text, locale: defaultLocale, context: context))
    }

    // MARK: - Helpers

    private static func resolveModelURL(_ source: IntentKitConfiguration.ModelSource) throws -> URL {
        switch source {
        case .url(let url):
            return url
        case .bundled(let name):
            // Looks in the app's main bundle. If you ship the model inside a package
            // target's resources, pass `.url(Bundle.module.url(...)!)` from that target.
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                throw IntentKitError.modelNotFound(name)
            }
            return url
        }
    }
}
