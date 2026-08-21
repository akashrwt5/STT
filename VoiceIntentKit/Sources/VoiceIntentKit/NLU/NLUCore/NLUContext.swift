// NLUContext.swift
// STT
//
// Conversational memory — the session & context layer of Dialogflow.
// Mirrors IntentClassifier/scripts/nlu/context.py.

import Foundation
import os.log

// Lifecycle tracing at `.debug`, which os_log does not emit unless someone turns it
// on — so it costs a host nothing and still answers "did this actually deallocate?".
// It was `print`, which a package has no business doing: it lands in the host app's
// console, unfiltered, with no subsystem to filter it out by.
private let lifecycleLog = Logger(subsystem: "com.voiceintentkit", category: "Lifecycle")

/// A named conversation context with a turn-based lifespan (e.g. a pending confirmation).
final class NLUConversationContext {
    let name: String
    var lifespan: Int
    var parameters: [String: String]

    init(name: String, lifespan: Int, parameters: [String: String] = [:]) {
        self.name = name
        self.lifespan = lifespan
        self.parameters = parameters
    }
}

/// Per-session mutable state: active contexts and in-progress slot filling.
///
/// **Thread safety**: `NLUSession` is `final class` (not an actor), but it is safe
/// to mark `@unchecked Sendable` because it is owned exclusively by `NLUEngine`,
/// which is declared `actor`. All reads and writes therefore happen on `NLUEngine`'s
/// serial executor — never concurrently. Do NOT vend this object outside `NLUEngine`
/// or store it on another actor without a new synchronisation strategy.
final class NLUSession: @unchecked Sendable {
    let sessionID: String
    private(set) var contexts: [String: NLUConversationContext] = [:]

    /// The intent currently collecting slots, if any.
    var pendingIntent: String?
    /// Slot values gathered so far for `pendingIntent`.
    var pendingSlots: [String: String] = [:]
    /// The specific slot whose prompt was last asked (the user's next utterance answers it).
    var awaitingSlot: String?
    /// When a date-time answer gives a day but no time ("tomorrow"), the resolved
    /// day (ISO, local midnight) is parked here so the follow-up time answer can be
    /// anchored to it, keeping the day instead of resolving against today.
    var partialDateTime: String?
    /// Number of consecutive turns where the awaited slot remained unfilled.
    /// Mirrors Python NLUEngine.MAX_SLOT_ATTEMPTS = 3: at 3 failures the engine
    /// abandons the flow and falls back to GenAI so the user is never trapped.
    var slotAttempts: Int = 0
    /// The classification breakdown from the first turn of a slot-filling flow.
    /// Preserved across turns so the final `.fulfill` card can show the eye button.
    var pendingBreakdown: ClassificationBreakdown?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    // MARK: - Contexts

    func setContext(_ name: String, lifespan: Int = 5, parameters: [String: String] = [:]) {
        contexts[name] = NLUConversationContext(name: name, lifespan: lifespan, parameters: parameters)
    }

    func hasContext(_ name: String) -> Bool {
        contexts[name] != nil
    }

    func clearContext(_ name: String) {
        contexts.removeValue(forKey: name)
    }

    /// Ages all contexts by one turn, dropping any that expire. Called on fresh-intent turns.
    func decrementContexts() {
        for (name, ctx) in contexts {
            ctx.lifespan -= 1
            if ctx.lifespan <= 0 {
                contexts.removeValue(forKey: name)
            }
        }
    }

    // MARK: - Slot filling

    func resetSlotFilling() {
        pendingIntent = nil
        pendingSlots = [:]
        awaitingSlot = nil
        partialDateTime = nil
        slotAttempts = 0
        pendingBreakdown = nil
    }

    /// Full reset — drops contexts and slot-filling state. Used when starting over.
    func resetAll() {
        contexts.removeAll()
        resetSlotFilling()
    }

    deinit {
        lifecycleLog.debug("[Deinit] NLUSession")
    }
}
