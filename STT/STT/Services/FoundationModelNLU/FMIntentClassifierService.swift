// FMIntentClassifierService.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// The Foundation Models classifier behind the same `IntentClassifying` seam
// the CoreML cascade uses — NLUEngine, slot filling, confirmation, context,
// and TTS are all inherited untouched (plan §3).
//
// GATING DECISION (plan §5): FoundationModels exposes no logprobs, so there
// is no calibrated confidence to threshold. In-scope results are therefore
// returned with `semanticRescue: true`, which NLUEngine already defines as
// "acceptance was decided by the producing model — do not re-apply the
// calibrated 0.70 gate" (see NLUEngine.handleNewIntent). The model's
// self-rating rides along for display only. outOfScope maps to
// "Default Fallback Intent" with `semanticRescue: false`, which routes to the
// engine's existing fallback path — identical UX to a cascade miss.
//
// SESSION LIFECYCLE — stateless per turn. Field finding from the first device
// run: a shared session accumulates its transcript, which (a) grew per-turn
// latency 791ms → 2847ms across eight turns, (b) overflowed the context
// window, and (c) contaminated classification — the identical utterance
// "Change memory" classified correctly on turn 1 and as out-of-scope on
// turn 3 because the model read the repetition against its history.
// Classification needs zero history (conversation state lives in NLUContext),
// so every turn gets a fresh session. The next turn's session is created and
// prewarmed immediately after each response — instruction processing overlaps
// the seconds the user spends speaking, keeping per-turn latency flat.

import Foundation
import os.log
#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, *)
public actor FMIntentClassifierService: IntentClassifying {

    private var session: LanguageModelSession
    private let logger = Logger(subsystem: "com.stt.module", category: "FMIntentClassifier")
    /// Display floor for in-scope results whose self-rating comes back
    /// implausibly low — purely cosmetic, never used for gating.
    private static let displayConfidenceFloor = 0.05

    public init() {
        #if DEBUG
        assert(FMPromptBuilder.estimatedTokenCount < FMPromptBuilder.instructionTokenBudget,
               "FM instruction catalog (\(FMPromptBuilder.estimatedTokenCount) est. tokens) exceeds budget")
        #endif
        self.session = Self.makeSession()
    }

    deinit {
        print("[Deinit] FMIntentClassifierService")
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(instructions: FMPromptBuilder.instructions())
    }

    // MARK: - IntentClassifying

    public func classifyAsync(_ text: String) async -> ClassificationResult {
        let started = ContinuousClock.now
        do {
            let output = try await respond(to: text, allowRetry: true)
            let elapsed = started.duration(to: .now)
            let label = output.intent.label
            let selfRating = min(max(output.confidence, Self.displayConfidenceFloor), 1.0)
            FMMetrics.record(utterance: text, label: label,
                             selfRating: selfRating, duration: elapsed, failed: false)

            // Reported as "stage 2" in the breakdown because that is the slot
            // the debug UI renders as "the model stage". The FM badge on
            // FMVoiceView is what tells the evaluator which engine answered.
            let stage = ClassificationBreakdown.StageResult(
                stage: 2, intent: label, confidence: selfRating)
            let breakdown = ClassificationBreakdown(
                winningStage: output.intent == .outOfScope ? nil : 2,
                stage2: stage, stage3: nil)

            if output.intent == .outOfScope {
                // semanticRescue false → NLUEngine routes to its fallback path.
                return ClassificationResult(label: label, confidence: selfRating,
                                            semanticRescue: false, breakdown: breakdown)
            }
            // semanticRescue true → guided output is accepted as-is; the
            // engine's calibrated threshold is not applied to an uncalibrated
            // self-rating (see header).
            return ClassificationResult(label: label, confidence: selfRating,
                                        semanticRescue: true, breakdown: breakdown)
        } catch {
            let elapsed = started.duration(to: .now)
            logger.error("FM classification failed: \(String(describing: error))")
            FMMetrics.record(utterance: text, label: "<error>",
                             selfRating: 0, duration: elapsed, failed: true)
            // Same shape a cascade miss produces → engine shows the standard
            // fallback card instead of erroring the session.
            let breakdown = ClassificationBreakdown(winningStage: nil, stage2: nil, stage3: nil)
            return ClassificationResult(label: "Default Fallback Intent", confidence: 0,
                                        semanticRescue: false, breakdown: breakdown)
        }
    }

    /// GenAI fallback URL — mirrors the cascade services so out-of-scope turns
    /// render the same fallback card. The FM sample never configures a real
    /// backend; this exists to satisfy the protocol and keep UX parity.
    public func genaiURL(for text: String) -> URL {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: "https://genai.yourcompany.com/?q=" + encoded)!
    }

    /// Pre-warms the language model session (plan §7: prewarm on screen entry,
    /// not first utterance, so the first turn's latency measurement is honest).
    public func warmUp() async {
        session.prewarm()
        logger.info("FM session prewarmed; instructions ≈\(FMPromptBuilder.estimatedTokenCount) tokens")
    }

    /// Stage 3 lifecycle is a CoreML-cascade concept; the FM path has no
    /// separately loadable stage. No-ops keep the protocol satisfied and the
    /// existing readiness UI truthful ("ready" immediately).
    public func loadStage3() async {}
    public func releaseStage3() async {}

    // MARK: - Session plumbing

    private func respond(to text: String, allowRetry: Bool) async throws -> FMClassificationOutput {
        // Take the prewarmed session for this turn and immediately stage a
        // fresh one for the next turn (see header: stateless per turn).
        let turnSession = session
        rotateSession()
        do {
            let response = try await turnSession.respond(
                to: text,
                generating: FMClassificationOutput.self,
                options: GenerationOptions(sampling: .greedy)
            )
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            // Single-turn prompts shouldn't overflow, but keep the recovery as
            // a belt-and-braces path (e.g. a pathologically long transcript).
            if case .exceededContextWindowSize = error, allowRetry {
                logger.info("FM context window exceeded on a single turn — retrying with a fresh session")
                return try await respond(to: text, allowRetry: false)
            }
            throw error
        }
    }

    /// Replaces the staged session with a fresh, prewarmed one. Called after
    /// handing the previous session to a turn, so instruction processing runs
    /// while the user is still speaking their next utterance.
    private func rotateSession() {
        session = Self.makeSession()
        session.prewarm()
    }
}
#endif
