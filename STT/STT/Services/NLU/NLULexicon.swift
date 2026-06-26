// NLULexicon.swift
// STT
//
// Phase 0 word-lists injectable into NLUEngine.
// Decoded from nlu_lexicon.<lang>.json in the Localization/ bundle subdirectory.

import Foundation

public struct NLULexicon: Decodable, Sendable {
    public let uncertain: [String]
    public let noIdioms: [String]
    public let carrierPhrases: [String]

    enum CodingKeys: String, CodingKey {
        case uncertain
        case noIdioms = "no_idioms"
        case carrierPhrases = "carrier_phrases"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uncertain     = (try? c.decodeIfPresent([String].self, forKey: .uncertain))     ?? []
        noIdioms      = (try? c.decodeIfPresent([String].self, forKey: .noIdioms))      ?? []
        carrierPhrases = (try? c.decodeIfPresent([String].self, forKey: .carrierPhrases)) ?? []
    }
}
