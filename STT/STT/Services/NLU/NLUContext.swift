// NLUContext.swift
// STT
//
// Conversational memory — the session & context layer of Dialogflow.
// Mirrors IntentClassifier/scripts/nlu/context.py.

import Foundation

/// A named conversation context with a turn-based lifespan (e.g. a pending confirmation).
public final class NLUConversationContext {
    public let name: String
    public var lifespan: Int
    public var parameters: [String: String]

    public init(name: String, lifespan: Int, parameters: [String: String] = [:]) {
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
public final class NLUSession: @unchecked Sendable {
    public let sessionID: String
    public private(set) var contexts: [String: NLUConversationContext] = [:]

    /// The intent currently collecting slots, if any.
    public var pendingIntent: String?
    /// Slot values gathered so far for `pendingIntent`.
    public var pendingSlots: [String: String] = [:]
    /// The specific slot whose prompt was last asked (the user's next utterance answers it).
    public var awaitingSlot: String?
    /// When a date-time answer gives a day but no time ("tomorrow"), the resolved
    /// day (ISO, local midnight) is parked here so the follow-up time answer can be
    /// anchored to it, keeping the day instead of resolving against today.
    public var partialDateTime: String?
    /// Number of consecutive turns where the awaited slot remained unfilled.
    /// Mirrors Python NLUEngine.MAX_SLOT_ATTEMPTS = 3: at 3 failures the engine
    /// abandons the flow and falls back to GenAI so the user is never trapped.
    public var slotAttempts: Int = 0
    /// The classification breakdown from the first turn of a slot-filling flow.
    /// Preserved across turns so the final `.fulfill` card can show the eye button.
    public var pendingBreakdown: ClassificationBreakdown?

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    // MARK: - Contexts

    public func setContext(_ name: String, lifespan: Int = 5, parameters: [String: String] = [:]) {
        contexts[name] = NLUConversationContext(name: name, lifespan: lifespan, parameters: parameters)
    }

    public func hasContext(_ name: String) -> Bool {
        contexts[name] != nil
    }

    public func clearContext(_ name: String) {
        contexts.removeValue(forKey: name)
    }

    /// Ages all contexts by one turn, dropping any that expire. Called on fresh-intent turns.
    public func decrementContexts() {
        for (name, ctx) in contexts {
            ctx.lifespan -= 1
            if ctx.lifespan <= 0 {
                contexts.removeValue(forKey: name)
            }
        }
    }

    // MARK: - Slot filling

    public func resetSlotFilling() {
        pendingIntent = nil
        pendingSlots = [:]
        awaitingSlot = nil
        partialDateTime = nil
        slotAttempts = 0
        pendingBreakdown = nil
    }

    /// Full reset — drops contexts and slot-filling state. Used when starting over.
    public func resetAll() {
        contexts.removeAll()
        resetSlotFilling()
    }
}
