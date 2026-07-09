// NLWordTokenizer.swift
// IntentKitCoreML
//
// NaturalLanguage-backed tokenizer with retained character spans. Lives in the
// CoreML target because it depends on the NaturalLanguage framework; apps that
// want a zero-framework default can use `SimpleWordTokenizer` from IntentKitCore.

import Foundation
import NaturalLanguage
import IntentKitCore

public struct NLWordTokenizer: Tokenizer {
    public init() {}
    public func tokenize(_ text: String, locale: Locale) -> [Token] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let lang = NLLanguage(rawValueOrNil: locale.language.languageCode?.identifier) {
            tokenizer.setLanguage(lang)
        }
        var tokens: [Token] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sub = String(text[range])
            if !sub.isEmpty { tokens.append(Token(text: sub, range: range)) }
            return true
        }
        return tokens
    }
}

private extension NLLanguage {
    init?(rawValueOrNil raw: String?) {
        guard let raw else { return nil }
        self = NLLanguage(raw)
    }
}
