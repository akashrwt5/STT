// PackProvider.swift
// VoiceAIKit
//
// The boundary between "get the bytes" and "trust the bytes".
//
// VoiceAIKit never opens a socket. A host hands it a local file URL; the SDK
// verifies, loads, binds and — later — hot-swaps. That split is not squeamishness
// about networking, it is where the knowledge actually lives:
//
//  · Auth, CDN base URLs and certificate pinning are the app's. An SDK that
//    fetches needs credentials and tenant config it has no business holding, and
//    every host already has a networking stack with its own retry and telemetry.
//  · iOS background transfer is app-level by construction — a background
//    `URLSession` needs `handleEventsForBackgroundURLSession` on the app
//    delegate. An SDK cannot own that cleanly.
//  · Download on cellular? Prompt before 5 MB? Evict which pack when storage is
//    low? Those are product decisions. An SDK that answers them gives every app
//    the same answer.
//  · Enterprise and MDM deployments pre-provision or proxy assets. An SDK that
//    insists on its own URL breaks them.
//
// What the SDK does keep is the part no host should reimplement: the ed25519 +
// sha256 trust chain, the `min_runtime_contract` check, language binding, and
// refusing a pack rather than degrading to one that happens to be lying around.
//
// WHY THIS REPLACES `LanguagePackRegistry`
//
// The registry enumerated `Bundle.module` — the languages compiled into the
// binary. A language released after the app shipped can never appear in that
// list, which makes it unfit for a product that will add languages over time.
// The question "which languages exist?" belongs to whoever publishes packs, not
// to a binary that was built before they were published.

import Foundation

/// Supplies a verified-on-disk pack for a language. Implemented by the host.
public protocol PackProvider: Sendable {

    /// A LOCAL file URL for `language`'s pack directory.
    ///
    /// How it got there — bundled, downloaded, pre-provisioned by MDM — is the
    /// host's business. The SDK will verify it before trusting a byte of it.
    ///
    /// - Throws: anything the host likes. It surfaces to the caller unchanged,
    ///   so a network error stays a network error rather than being flattened
    ///   into "pack not found".
    func packURL(for language: String) async throws -> URL
}

/// A provider over URLs the host already has on disk.
///
/// The obvious implementation, and deliberately the only one shipped: no
/// discovery, no directory scanning, no naming convention. The host says which
/// URL belongs to which language, because the alternative is the SDK guessing
/// from filenames — which is what the registry did.
///
/// Typical use is the seed pack seeded into the app's own bundle:
///
/// ```swift
/// let seed = Bundle.main.url(forResource: "pack-en-v1.0.30", withExtension: nil)!
/// let provider = StaticPackProvider(["en": seed])
/// ```
///
/// Note `Bundle.main` — the APP's bundle. The SDK still ships no data; the app
/// chooses to pre-install one pack so the first launch works offline. Crucially
/// that seed loads through the same path as a downloaded pack. The predecessor's
/// mistake was a separate code path for the default language, which then became
/// the fallback everything silently landed on.
public struct StaticPackProvider: PackProvider {

    private let urls: [String: URL]

    /// The languages this provider can serve, sorted.
    ///
    /// Exposed so a host can decide BEFORE constructing a session whether the
    /// language it wants is available — see `VoiceIntentError.languageUnavailable`,
    /// which carries the same list after the fact. Deciding up front is better:
    /// the choice of language also decides the speech recogniser's locale, and
    /// that has to be made once, together.
    public var languages: [String] { urls.keys.sorted() }

    public init(_ urls: [String: URL]) {
        self.urls = urls
    }

    /// Convenience for a host that supports exactly one language today.
    public init(language: String, url: URL) {
        self.urls = [language: url]
    }

    public func packURL(for language: String) async throws -> URL {
        guard let url = urls[language] else {
            throw VoiceIntentError.languageUnavailable(
                requested: language,
                available: urls.keys.sorted())
        }
        return url
    }
}
