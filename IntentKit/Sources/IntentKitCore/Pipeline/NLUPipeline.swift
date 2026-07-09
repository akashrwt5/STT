// NLUPipeline.swift
// IntentKitCore
//
// Runs the ordered stage chain. Every stage is injected as a protocol, so the
// pipeline is fully composable and each stage is independently testable.

import Foundation

public struct NLUPipeline: Sendable {

    private let preprocessor: any TextPreprocessor
    private let normalizer: any TextNormalizer
    private let tokenizer: any Tokenizer
    private let embedder: any EmbeddingProvider
    private let backend: any IntentClassifierBackend
    private let calibrator: any ConfidenceCalibrator
    private let contextManager: any ContextManager
    private let policy: any DecisionPolicy
    private let postProcessor: any IntentPostProcessor

    public init(
        preprocessor: any TextPreprocessor,
        normalizer: any TextNormalizer,
        tokenizer: any Tokenizer,
        embedder: any EmbeddingProvider,
        backend: any IntentClassifierBackend,
        calibrator: any ConfidenceCalibrator,
        contextManager: any ContextManager,
        policy: any DecisionPolicy,
        postProcessor: any IntentPostProcessor
    ) {
        self.preprocessor = preprocessor
        self.normalizer = normalizer
        self.tokenizer = tokenizer
        self.embedder = embedder
        self.backend = backend
        self.calibrator = calibrator
        self.contextManager = contextManager
        self.policy = policy
        self.postProcessor = postProcessor
    }

    /// Executes the full pipeline for one request.
    public func run(_ request: NLURequest) async throws -> IntentResult {
        let clock = ContinuousClock()
        let start = clock.now

        // 1. Preprocess + fast empty-input path (never touches the model).
        let cleaned = preprocessor.preprocess(request.text, locale: request.locale)
        guard !cleaned.isEmpty else {
            return IntentResult(
                decision: .unknown(.emptyInput),
                locale: request.locale,
                latency: start.duration(to: clock.now)
            )
        }

        // 2. Normalize.
        let normalized = normalizer.normalize(cleaned, locale: request.locale)

        // 3. Tokenize (spans retained for slot extraction).
        let tokens = tokenizer.tokenize(normalized, locale: request.locale)

        // 4. Embed.
        let embedding = try await embedder.embed(tokens: tokens, originalText: request.text, locale: request.locale)

        // 5. Classify → raw logits.
        let logits = try await backend.predict(embedding)

        // 6. Calibrate → probabilities.
        let calibrated = calibrator.calibrate(logits)

        // 7. Context enrichment (no-op for single-turn apps).
        let enriched = contextManager.enrich(calibrated, context: request.context)

        // 8. Decide (threshold / margin / OOD).
        let decision = policy.decide(enriched, context: request.context)

        // 9. Post-process (slots, label mapping).
        let (finalDecision, slots) = postProcessor.postProcess(
            decision: decision, tokens: tokens, originalText: request.text
        )

        let ranked = enriched.sorted { $0.confidence > $1.confidence }
        return IntentResult(
            decision: finalDecision,
            alternatives: Array(ranked.prefix(3)),
            slots: slots,
            locale: request.locale,
            latency: start.duration(to: clock.now)
        )
    }
}
