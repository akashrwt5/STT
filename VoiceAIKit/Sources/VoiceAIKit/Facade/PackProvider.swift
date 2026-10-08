// PackProvider.swift
// VoiceAIKit
//
// How a host app tells the SDK where a language's pack is.
//
// A provider does one thing: given a language code, it returns the local URL of
// that language's pack directory. It does not verify, load or cache anything.
// The SDK verifies the pack itself (signature, checksums, minimum runtime version,
// language), so a provider cannot weaken those checks.
//
// The SDK never downloads packs. Where a pack comes from (bundled with the app,
// downloaded over the air, provisioned by MDM) is up to the host app.

import Foundation

/// Returns the local location of a language's pack. Implemented by the host app.
public protocol PackProvider: Sendable {

    /// The pack directory for `language`, as a local file URL.
    ///
    /// The SDK calls this each time it builds an engine, for example on `start()`.
    /// Return the pack that should be used now, so an app that installs newer packs
    /// picks the new one up on the next call.
    ///
    /// The SDK verifies the returned pack before using it. If verification fails it
    /// throws; it does not fall back to a different pack.
    ///
    /// - Parameter language: The configured language's `languageCode`, e.g. `"en"`.
    /// - Returns: The directory that contains the pack's `bundle.json`.
    /// - Throws: Any error. The SDK does not wrap it, so a network failure stays a
    ///   network failure instead of turning into "pack not found". Throw
    ///   `VoiceIntentError.languageUnavailable` if you have no pack for `language`.
    func packURL(for language: String) async throws -> URL
}

/// A `PackProvider` that returns pack locations you gave it up front.
///
/// Give it a language code and the URL of that language's pack folder (for example
/// "en" and the English pack folder). When the SDK asks for "en", it returns that URL.
/// Use it when you already know where the pack is, such as a pack shipped with the app.
public struct StaticPackProvider: PackProvider {

    private let urls: [String: URL]

    /// The language codes this provider serves, sorted.
    ///
    /// Use it before creating a session to check that the language you want is
    /// available. If a session asks for a language that is not listed here,
    /// `packURL(for:)` throws `VoiceIntentError.languageUnavailable` with this list.
    public var languages: [String] { urls.keys.sorted() }

    /// - Parameter urls: Language code to pack directory URL.
    public init(_ urls: [String: URL]) {
        self.urls = urls
    }

    /// Convenience for a host that supports a single language.
    public init(language: String, url: URL) {
        self.urls = [language: url]
    }

    /// Returns the URL registered for `language`. It does not touch the disk; the
    /// SDK checks the pack when it loads it.
    ///
    /// - Throws: `VoiceIntentError.languageUnavailable` if `language` is not in
    ///   the map.
    public func packURL(for language: String) async throws -> URL {
        guard let url = urls[language] else {
            throw VoiceIntentError.languageUnavailable(
                requested: language,
                available: urls.keys.sorted())
        }
        return url
    }
}
