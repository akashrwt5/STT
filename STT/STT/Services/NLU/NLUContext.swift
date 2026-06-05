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
public final class NLUSession {
    public let sessionID: String
    public private(set) var contexts: [String: NLUConversationContext] = [:]

    /// The intent currently collecting slots, if any.
    public var pendingIntent: String?
    /// Slot values gathered so far for `pendingIntent`.
    public var pendingSlots: [String: String] = [:]
    /// The specific slot whose prompt was last asked (the user's next utterance answers it).
    public var awaitingSlot: String?

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
    }

    /// Full reset — drops contexts and slot-filling state. Used when starting over.
    public func resetAll() {
        contexts.removeAll()
        resetSlotFilling()
    }
}
