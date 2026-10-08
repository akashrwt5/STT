// FoundationModelCascade.swift
// VoiceAIKit
//
// Puts a generative intent model in front of, or behind, the pack classifier,
// as one `IntentClassifying`. `NLUEngine` does not know it is there.
//
//   foundation_model        the generative model labels every turn; the pack
//                           classifier still runs and its reading is kept in
//                           the breakdown for comparison.
//   pack_with_fm_fallback   the pack classifier labels the turn; the generative
//                           model is asked only when that answer would end in
//                           the fallback intent.
//   pack_only               never built: the factory returns the pack classifier.
//
// In both modes the pack classifier's answer is returned whenever the
// generative model gives none (unavailable device, refusal, error), so a device
// without Apple Intelligence behaves exactly as it does without this stage.
//
// A generative answer is reported with `semanticRescue: false`. The engine
// skips its confidence bar for a semantic-rescue result, and a self-rated
// confidence must not skip it.

import Foundation
import os.log

actor FoundationModelCascade: IntentClassifying {

    private static let log = Logger(subsystem: "com.voiceaikit", category: "FoundationModelCascade")

    /// Breakdown stage number for a generative answer. Shares the slot the
    /// semantic stage uses, so the existing debug UI shows it without changes.
    static let generativeStage = 3

    /// The bars the engine applies after classification, read from the same
    /// pack, so "would this end in the fallback?" is answered the way the engine
    /// will answer it.
    struct Bars: Sendable, Equatable {
        let confidence: Double
        let agreement: Double?
        let oovReject: Double?
        let oovBypass: Double?
    }

    private let base: any IntentClassifying
    private let generative: any GenerativeIntentClassifying
    private let mode: IntentClassifierMode
    private let outOfScopeIntent: String
    private let bars: Bars

    /// True when the generative model chose the label of the most recent
    /// `classifyAsync` call. The engine asks follow-up questions about that turn
    /// (`oovRatio`, `calibratedConfidence`), and the answers depend on who chose.
    private var generativeDecidedLastTurn = false

    init(base: any IntentClassifying,
         generative: any GenerativeIntentClassifying,
         mode: IntentClassifierMode,
         outOfScopeIntent: String,
         bars: Bars) {
        self.base = base
        self.generative = generative
        self.mode = mode
        self.outOfScopeIntent = outOfScopeIntent
        self.bars = bars
    }

    // MARK: - Classification

    func classifyAsync(_ text: String) async -> ClassificationResult {
        let packResult = await base.classifyAsync(text)

        switch mode {
        case .foundationModel:
            break
        case .packWithFoundationModelFallback:
            guard await wouldFallBack(packResult, text: text) else {
                generativeDecidedLastTurn = false
                return packResult
            }
        case .packOnly:
            // The factory does not build a cascade for this mode. Answering
            // like the pack keeps the type total if one is built anyway.
            generativeDecidedLastTurn = false
            return packResult
        }

        guard let verdict = await generative.classify(text) else {
            generativeDecidedLastTurn = false
            return packResult
        }
        generativeDecidedLastTurn = true
        // Read into a local: `Logger` interpolation is an autoclosure, and
        // touching an actor property inside it is a capture of `self`.
        let modeName = mode.rawValue
        Self.log.notice("""
            generative mode=\(modeName, privacy: .public) \
            pack=\(packResult.label, privacy: .public)/\(packResult.confidence, privacy: .public) \
            model=\(verdict.intent, privacy: .public)/\(verdict.confidence, privacy: .public)
            """)
        return ClassificationResult(
            label: verdict.intent,
            confidence: verdict.confidence,
            semanticRescue: false,
            breakdown: ClassificationBreakdown(
                winningStage: Self.generativeStage,
                stage2: packResult.breakdown.stage2,
                stage3: .init(stage: Self.generativeStage,
                              intent: verdict.intent,
                              confidence: verdict.confidence)),
            arbitration: nil)
    }

    /// The pack classifier only. A slot answer is not a command, so asking a
    /// model trained to find commands in it invites a false topic switch, and
    /// the probe runs while the user waits on a prompt.
    func classifyForTopicSwitch(_ text: String) async -> ClassificationResult {
        generativeDecidedLastTurn = false
        return await base.classifyAsync(text)
    }

    // MARK: - Follow-up questions about the last turn

    /// Zero when the generative model chose the label: it reads every word, so
    /// the pack vocabulary's blind spots say nothing about its answer.
    func oovRatio(_ text: String) async -> Double {
        generativeDecidedLastTurn ? 0 : await base.oovRatio(text)
    }

    /// Nil when the generative model chose the label: it has no distribution
    /// over the other labels, and nil tells the engine to keep the confidence
    /// it has.
    func calibratedConfidence(for intent: String) async -> Double? {
        generativeDecidedLastTurn ? nil : await base.calibratedConfidence(for: intent)
    }

    // MARK: - Lifecycle

    func warmUp() async {
        await base.warmUp()
        await generative.prewarm()
    }

    func loadStage3() async { await base.loadStage3() }
    func releaseStage3() async { await base.releaseStage3() }

    // MARK: - Private

    /// True when the engine would send this pack result to the fallback intent:
    /// out of scope, under its confidence bar, or blocked by the
    /// out-of-vocabulary guard. Mirrors the checks in `NLUEngine.handleNewIntent`.
    private func wouldFallBack(_ result: ClassificationResult, text: String) async -> Bool {
        if result.label.isEmpty || result.label == outOfScopeIntent || result.label == "OUT_OF_SCOPE" {
            return true
        }
        let bar = result.arbitration == .corroborated
            ? (bars.agreement ?? bars.confidence)
            : bars.confidence
        if result.confidence < bar { return true }
        if let reject = bars.oovReject, let bypass = bars.oovBypass, result.confidence < bypass {
            return await base.oovRatio(text) >= reject
        }
        return false
    }
}
