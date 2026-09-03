// NLUProtocols.swift
// STT
//
// The abstraction layer that decouples the orchestration engine and the View
// layer from concrete classifier/engine types. Only `PackEngineFactory` names
// concrete types; everything above it depends on these protocols.

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
/// `PackClassifierAdapter` is the only conformer now; `IntentClassifierService`
/// and `MultilingualIntentClassifierService` were the bundle-loading pair it
/// replaced. `NLUEngine` depends only on this protocol and never names a
/// concrete classifier.
protocol IntentClassifying: Actor {
    /// Full 3-stage async classification — stage, confidence, and breakdown.
    func classifyAsync(_ text: String) async -> ClassificationResult
    /// Pre-warms the CoreML graphs (ANE specialisation) in the background.
    func warmUp() async
    /// Loads Stage 3 (MiniLM embedder + semantic head) and triggers ANE compile.
    func loadStage3() async
    /// Releases Stage 3 refs. Stage 3 is skipped on future classifications.
    func releaseStage3() async
    /// Share of the utterance's tokens the featurizer cannot represent, for the
    /// out-of-vocabulary guard. See `PackTFIDFVectorizer.oovRatio(_:)`.
    func oovRatio(_ text: String) async -> Double
}

extension IntentClassifying {
    /// A classifier that cannot report a vocabulary DISABLES the guard rather
    /// than having every turn refused — which is what the reference engine does
    /// ("Returns 0.0 when the backend cannot report a vocabulary"). Test doubles
    /// and any future non-TF-IDF stage land here.
    func oovRatio(_ text: String) async -> Double { 0 }
}

// MARK: - ConversationEngine

/// Contract the ViewModel depends on.
///
/// `LiveTranscriptionViewModel` stores `any ConversationEngine` and never names
/// `NLUEngine` directly, so the factory can return any conforming actor without
/// the ViewModel changing. Existential (`any`) is correct here because the engine
/// is a long-lived *stored* value, not a transient generic algorithm input.
protocol ConversationEngine: Actor {
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
enum SlotAnswerAssessment: Sendable {
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

extension ConversationEngine {
    /// Default: treat every answer as complete (fixed-window endpointing).
    func assessSlotAnswer(_ text: String) async -> SlotAnswerAssessment { .complete }
}

