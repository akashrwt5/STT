// VoiceIntentError.swift
// VoiceIntentKit
//
// Every way loading a pack can fail, as one typed enum.
//
// This exists because the pre-pack code had three `fatalError`s on missing
// resources (NLUSchema, IntentClassifierService, NLUEngineFactoryProvider).
// That was defensible when resources were compiled into the binary — a missing
// file was a build error you could not ship. With a downloaded, hot-swappable
// pack it is a runtime condition, and crashing the host app because a CDN
// served a truncated archive is not acceptable.
//
// The other half of the rule matters more: a pack that fails to load must
// THROW, never silently fall back. The old `LocalizationLoader` degraded to
// English on any error, and `NLULexicon` decoded every field with `try? … ?? []`
// so a wrong-shaped lexicon produced an empty struct and English word-lists with
// no log line. That is the failure mode this SDK is being rebuilt to eliminate:
// a French session quietly running English rules looks fine in testing and is
// wrong in the user's hands.

import Foundation

public enum VoiceIntentError: Error, Equatable, Sendable {

    // MARK: - Locating and reading

    /// No pack directory at the given URL.
    case packNotFound(URL)

    /// A file the pack declares (or the format requires) could not be read.
    case unreadableFile(path: String, reason: String)

    /// A file exists but is not the JSON the format says it is.
    case malformedJSON(path: String, reason: String)

    /// `bundle.json` declares an artifact that is not in the pack.
    ///
    /// Known offender: `models/semantic_head/shared/head.json` is declared but
    /// never emitted (BUG-013 in the compiler repo). The loader tolerates that
    /// one by policy — see `PackLoadPolicy.toleratedMissingArtifacts` — because
    /// refusing every current pack over a field nothing reads would be pedantry,
    /// not safety.
    case declaredArtifactMissing(path: String)

    // MARK: - Integrity (ADD §8)

    case integrityFileMissing(path: String)

    /// `sha256(integrity/manifest.sha256) != bundle.json.checksums_root`.
    /// This is the only thing binding `bundle.json`, which is deliberately not
    /// listed inside the manifest — so skipping it leaves the manifest unbound.
    case checksumsRootMismatch(expected: String, actual: String)

    /// A listed file's content does not match its recorded digest.
    case fileDigestMismatch(path: String)

    /// A file is present in the pack but absent from `manifest.sha256`, i.e.
    /// unsigned. Carries every offender so the caller can see junk (stray
    /// `.DS_Store`s) apart from something inserted.
    case unsignedFilesPresent([String])

    /// Ed25519 verification over `manifest.sha256 ‖ bundle.json` failed.
    case signatureInvalid

    /// No public key available for the pack's `key_id`.
    case signingKeyUnknown(keyID: String)

    /// The pack is signed, but the trust policy refuses it — e.g. a
    /// `channel: "dev"` pack in a release build, which ADR-005 Part 11 requires
    /// a production runtime to categorically refuse.
    case untrustedPack(reason: String)

    // MARK: - Compatibility

    case unsupportedFormatVersion(found: String, supportedMajor: Int)

    /// The pack's `engine_compat` range does not contain our runtime contract.
    case runtimeContractUnsupported(packMin: Int, packMaxTested: Int, ours: Int)

    /// `required_runtime_features` contains something this build does not
    /// implement. Fail closed: a feature we do not recognise may be the one
    /// that makes the pack's numbers valid.
    case unsupportedRuntimeFeatures([String])

    // MARK: - Language selection

    /// The requested language is not in `bundle.json.languages`.
    case languageUnavailable(requested: String, available: [String])

    /// No language requested and the pack carries several, so there is no
    /// defensible default. Packs are one-per-language today, but the format is
    /// a map and we will not guess if that changes.
    case languageAmbiguous(available: [String])

    /// The language is declared but its per-language files are absent.
    case languageIncomplete(language: String, missing: [String])

    // MARK: - Internal consistency

    /// A workflow references a response key with no string in the catalog.
    case danglingResponseKey(intent: String, key: String)

    /// A workflow's completion names an action no capability declares.
    case danglingActionKey(intent: String, action: String)

    /// A slot references an entity the pack does not define.
    case danglingEntityReference(intent: String, slot: String, entity: String)

    /// A guard redirects to an intent outside the pack's intent set.
    case danglingGuardIntent(from: String, to: String)

    /// `cascade.tfidf.output.dim` disagrees with the label count, i.e. the
    /// model and the label space were built from different runs.
    case labelCountMismatch(cascadeDim: Int, labels: Int)

    /// The classifier's label set and the schema's intent set differ.
    case labelSchemaMismatch(missingFromSchema: [String], missingFromLabels: [String])
}

// MARK: - Diagnostics

extension VoiceIntentError: CustomStringConvertible, LocalizedError {

    public var description: String {
        switch self {
        case .packNotFound(let url):
            return "No pack at \(url.path)"
        case .unreadableFile(let path, let reason):
            return "Cannot read \(path): \(reason)"
        case .malformedJSON(let path, let reason):
            return "Malformed JSON in \(path): \(reason)"
        case .declaredArtifactMissing(let path):
            return "bundle.json declares an artifact that is not in the pack: \(path)"
        case .integrityFileMissing(let path):
            return "Integrity file missing: \(path)"
        case .checksumsRootMismatch(let expected, let actual):
            return "checksums_root mismatch — bundle.json says \(expected), manifest hashes to \(actual)"
        case .fileDigestMismatch(let path):
            return "Digest mismatch for \(path) — the pack was modified after signing"
        case .unsignedFilesPresent(let paths):
            return "\(paths.count) file(s) present but not covered by manifest.sha256: \(paths.joined(separator: ", "))"
        case .signatureInvalid:
            return "Ed25519 signature does not verify over manifest.sha256 ‖ bundle.json"
        case .signingKeyUnknown(let keyID):
            return "No public key registered for signing key '\(keyID)'"
        case .untrustedPack(let reason):
            return "Pack refused by trust policy: \(reason)"
        case .unsupportedFormatVersion(let found, let supported):
            return "Pack format \(found) is not supported (this build reads major \(supported))"
        case .runtimeContractUnsupported(let min, let maxTested, let ours):
            return "Pack needs runtime contract \(min)…\(maxTested); this build implements \(ours)"
        case .unsupportedRuntimeFeatures(let features):
            return "Pack requires runtime feature(s) this build does not implement: \(features.joined(separator: ", "))"
        case .languageUnavailable(let requested, let available):
            return "Pack has no '\(requested)'; it carries: \(available.joined(separator: ", "))"
        case .languageAmbiguous(let available):
            return "Pack carries several languages (\(available.joined(separator: ", "))) — name one explicitly"
        case .languageIncomplete(let language, let missing):
            return "Language '\(language)' is declared but missing: \(missing.joined(separator: ", "))"
        case .danglingResponseKey(let intent, let key):
            return "Intent '\(intent)' references response key '\(key)', which has no string"
        case .danglingActionKey(let intent, let action):
            return "Intent '\(intent)' completes with action '\(action)', which no capability declares"
        case .danglingEntityReference(let intent, let slot, let entity):
            return "Slot '\(slot)' of '\(intent)' references undefined entity '\(entity)'"
        case .danglingGuardIntent(let from, let to):
            return "Guard redirects '\(from)' to '\(to)', which is not in the pack"
        case .labelCountMismatch(let dim, let labels):
            return "cascade.tfidf.output.dim is \(dim) but the pack has \(labels) labels"
        case .labelSchemaMismatch(let missingFromSchema, let missingFromLabels):
            return "Label/schema mismatch — absent from schema: \(missingFromSchema.prefix(5).joined(separator: ", ")); "
                 + "absent from labels: \(missingFromLabels.prefix(5).joined(separator: ", "))"
        }
    }

    public var errorDescription: String? { description }

    /// True when a different pack might succeed — the host can fall back to a
    /// previously-verified pack. False means the request itself was wrong
    /// (unknown language, unsupported contract) and retrying will not help.
    public var isPackDefect: Bool {
        switch self {
        case .languageUnavailable, .languageAmbiguous, .unsupportedRuntimeFeatures,
             .runtimeContractUnsupported, .unsupportedFormatVersion:
            return false
        default:
            return true
        }
    }
}
