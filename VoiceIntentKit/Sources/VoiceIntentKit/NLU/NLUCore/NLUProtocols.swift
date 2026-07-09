// NLUProtocols.swift
// STT
//
// The abstraction layer that decouples the orchestration engine and the View
// layer from concrete classifier/engine types. Only NLUEngineFactoryProvider
// names concrete classifiers; everything above it depends on these protocols.

import Foundation

// MARK: - IntentClassifying

/// Contract every Stage-2 classifier must satisfy.
///
/// Declared as `Actor` so callers must `await` every member: the actor provides
/// both off-main execution and serialisation of mutable state (`coreMLModel`,
/// `logRegWeights`, `semanticEmbedder`) without locks or `@unchecked Sendable`.
/// Actors cannot inherit, so a protocol — not a base class — is the idiomatic
/// Swift-concurrency composition model here; it also lets the test suite inject
/// a mock conformer with zero production impact.
///
/// Both `IntentClassifierService` (English) and `MultilingualIntentClassifierService`
/// conform. `NLUEngine` depends only on this protocol — it never names a
/// concrete classifier type.
public protocol IntentClassifying: Actor {
    /// Full 3-stage async classification — stage, confidence, and breakdown.
    func classifyAsync(_ text: String) async -> ClassificationResult
    /// GenAI fallback URL for an unrecognised query.
    func genaiURL(for text: String) -> URL
    /// Pre-warms the CoreML graphs (ANE specialisation) in the background.
    func warmUp() async
    /// Loads Stage 3 (MiniLM embedder + semantic head) and triggers ANE compile.
    func loadStage3() async
    /// Releases Stage 3 refs. Stage 3 is skipped on future classifications.
    func releaseStage3() async
}

// MARK: - ConversationEngine

/// Contract the ViewModel depends on.
///
/// `LiveTranscriptionViewModel` stores `any ConversationEngine` and never names
/// `NLUEngine` directly, so the factory can return any conforming actor without
/// the ViewModel changing. Existential (`any`) is correct here because the engine
/// is a long-lived *stored* value, not a transient generic algorithm input.
public protocol ConversationEngine: Actor {
    /// Processes one user utterance and returns the next conversational step.
    func handle(_ text: String) async -> NLUResponse
    /// Abandons any in-progress conversation (slot filling / confirmation).
    func reset() async
    /// True when the engine is mid-conversation and the next utterance is an answer.
    var isCollecting: Bool { get async }
    /// Loads Stage 3 on the underlying classifier.
    func loadStage3() async
    /// Releases Stage 3 on the underlying classifier.
    func releaseStage3() async
    /// Pre-warms the underlying classifier's CoreML graphs.
    func warmUp() async

    /// Content-aware endpointing hook. Given the current stable (not yet final)
    /// transcript, assesses how confident the engine is that it forms a finished
    /// answer to whatever it is currently awaiting. The endpointing layer maps the
    /// verdict to a confirmation window: verified-complete answers endpoint fast,
    /// unverifiable free text gets a medium window, verifiably unfinished answers
    /// get an extended one — so a thinking pause ("tomorrow… …5 AM", "drink…
    /// …water") doesn't split one answer into two turns.
    /// Returns `.complete` when not mid-conversation (open commands endpoint normally).
    func assessSlotAnswer(_ text: String) async -> SlotAnswerAssessment
}

/// Endpointing verdict for an in-progress slot answer.
public enum SlotAnswerAssessment: Sendable {
    /// Verified complete (e.g. a date-time with an explicit time, a matched enum
    /// value). Safe to endpoint at the fast window.
    case complete
    /// Free-form text whose completeness cannot be verified ("drink" vs "drink
    /// water" — no rule can tell). Use the medium window.
    case freeform
    /// Verifiably unfinished (bare day for a date-time slot, trailing function
    /// word, empty). Use the extended window.
    case incomplete
}

public extension ConversationEngine {
    /// Default: treat every answer as complete (fixed-window endpointing).
    func assessSlotAnswer(_ text: String) async -> SlotAnswerAssessment { .complete }
}

// MARK: - NLUEngineFactory

/// Creates a fully configured `ConversationEngine`.
///
/// Concrete factories live in `NLUEngineFactoryProvider` — the single place in
/// the codebase that names concrete classifier types. Adding a third variant is
/// a new conforming struct plus one new case in `NLUEngineFactoryProvider.make(for:)`,
/// with zero edits to `NLUEngine`, `LiveTranscriptionViewModel`, or `PVAViewModel`.
///
/// `Sendable` because engine construction is expensive (CoreML model load +
/// multi-MB weights JSON parse) and runs on a background task — the factory
/// value crosses that isolation boundary. Conformers must be stateless (both
/// current ones are empty structs).
public protocol NLUEngineFactory: Sendable {
    func makeEngine() -> any ConversationEngine
    func makeEngine(language: String) -> any ConversationEngine
}

extension NLUEngineFactory {
    /// Default: language-unaware factories forward to the English engine.
    public func makeEngine(language: String) -> any ConversationEngine { makeEngine() }
}
