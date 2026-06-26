// LocalizationLoader.swift
// STT
//
// Merge-based localization loader for NLU schema, entities, and word-lists.
// Canonical JSON is the source of truth for structure; overlays patch strings only.

import Foundation
import OSLog

public enum LocalizationLoader {

    private static let log = Logger(subsystem: "com.starkey.stt", category: "LocalizationLoader")

    // MARK: - Public API

    /// Returns an NLUSchema for `language`, merged from the canonical English schema
    /// and a strings-only overlay (nlu_schema.<lang>.json). Falls back to English on error.
    public static func schema(language: String) -> NLUSchema {
        guard language != "en", language != "en-US" else { return .loadFromBundle() }

        guard let canonURL = bundleURL(name: "nlu_schema", ext: "json"),
              let canonData = try? Data(contentsOf: canonURL),
              var canon = try? JSONSerialization.jsonObject(with: canonData) as? [String: Any]
        else {
            log.error("LocalizationLoader: failed to load canonical nlu_schema.json")
            return .loadFromBundle()
        }

        guard let overlayURL = bundleURL(name: "nlu_schema.\(language)", ext: "json"),
              let overlayData = try? Data(contentsOf: overlayURL),
              let overlay = try? JSONSerialization.jsonObject(with: overlayData) as? [String: Any]
        else {
            log.error("LocalizationLoader: nlu_schema.\(language).json missing or undecodable — using English")
            return .loadFromBundle()
        }

        mergeOverlay(overlay, into: &canon)

        guard let merged = try? JSONSerialization.data(withJSONObject: canon),
              let result = try? JSONDecoder().decode(NLUSchema.self, from: merged)
        else {
            log.error("LocalizationLoader: merged schema decode failed for \(language) — using English")
            return .loadFromBundle()
        }
        return result
    }

    /// Returns the URL for nlu_entities.<lang>.json, falling back to English.
    public static func entitiesURL(language: String) -> URL? {
        guard language != "en", language != "en-US" else {
            return bundleURL(name: "nlu_entities", ext: "json")
        }
        if let url = bundleURL(name: "nlu_entities.\(language)", ext: "json") { return url }
        log.error("LocalizationLoader: nlu_entities.\(language).json missing — using English")
        return bundleURL(name: "nlu_entities", ext: "json")
    }

    /// Returns an NLULexicon for `language`, or nil if the file is missing or undecodable.
    /// Nil callers fall back to NLUEngine static English defaults.
    public static func lexicon(language: String) -> NLULexicon? {
        guard let url = bundleURL(name: "nlu_lexicon.\(language)", ext: "json") else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            log.error("LocalizationLoader: could not read nlu_lexicon.\(language).json")
            return nil
        }
        guard let lex = try? JSONDecoder().decode(NLULexicon.self, from: data) else {
            log.error("LocalizationLoader: nlu_lexicon.\(language).json decode failed")
            return nil
        }
        return lex
    }

    // MARK: - Merge

    /// Patches strings-only overlay fields into the canonical schema dict.
    /// Only touches: affirmative, negative, intents[*].fulfillment,
    /// intents[*].slots[*].prompt, intents[*].followup prompt/yes/no fulfillment.
    /// Never adds or removes schema keys; never touches entity/required/action.
    private static func mergeOverlay(_ overlay: [String: Any], into canon: inout [String: Any]) {
        if let aff = overlay["affirmative"] as? [String] { canon["affirmative"] = aff }
        if let neg = overlay["negative"]    as? [String] { canon["negative"]    = neg }

        guard let overlayIntents = overlay["intents"] as? [String: Any],
              var canonIntents   = canon["intents"]   as? [String: Any]
        else { return }

        for (name, raw) in overlayIntents {
            guard let ovIntent = raw as? [String: Any] else { continue }
            var canonIntent = canonIntents[name] as? [String: Any] ?? [:]

            if let f = ovIntent["fulfillment"] as? String { canonIntent["fulfillment"] = f }

            // Slot prompts: match by slot name.
            if let ovSlots = ovIntent["slots"] as? [[String: Any]],
               var canonSlots = canonIntent["slots"] as? [[String: Any]] {
                for ovSlot in ovSlots {
                    guard let slotName = ovSlot["name"]   as? String,
                          let prompt   = ovSlot["prompt"] as? String else { continue }
                    if let idx = canonSlots.firstIndex(where: { ($0["name"] as? String) == slotName }) {
                        var s = canonSlots[idx]; s["prompt"] = prompt; canonSlots[idx] = s
                    }
                }
                canonIntent["slots"] = canonSlots
            }

            // Followup prompt + branch fulfillments.
            if let ovFU = ovIntent["followup"] as? [String: Any],
               var canonFU = canonIntent["followup"] as? [String: Any] {
                if let p = ovFU["prompt"] as? String { canonFU["prompt"] = p }
                for branch in ["yes", "no"] {
                    if let ovB = ovFU[branch] as? [String: Any],
                       var canonB = canonFU[branch] as? [String: Any] {
                        if let f = ovB["fulfillment"] as? String { canonB["fulfillment"] = f }
                        canonFU[branch] = canonB
                    }
                }
                canonIntent["followup"] = canonFU
            }

            canonIntents[name] = canonIntent
        }
        canon["intents"] = canonIntents
    }

    // MARK: - Bundle lookup

    private static func bundleURL(name: String, ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Localization")
            ?? Bundle.main.url(forResource: name, withExtension: ext)
    }
}
