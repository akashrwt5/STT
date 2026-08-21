// NLUBundle.swift
// VoiceIntentKit
//
// A typed model of `bundle.json` — the pack's root descriptor.
//
// Decoding is STRICT. Everywhere else in this package's history, decoding was
// tolerant (`try? … ?? []`), which is why a wrong-shaped lexicon could silently
// produce English word-lists. A manifest that does not decode means we do not
// know what we are holding, and the only safe response is to throw.
//
// `bundle.json` is deliberately absent from `integrity/manifest.sha256`; it is
// bound to the pack only through `checksums_root`. See `PackIntegrity`.

import Foundation

/// The runtime contract this build of VoiceIntentKit implements. A pack
/// declares the range it needs in `engine_compat`; outside that range we refuse
/// rather than degrade, because the pack's report card was measured against
/// behaviour we may not have.
let VIKRuntimeContract: Int = 1

/// Pack format major version this build can read.
let VIKSupportedFormatMajor: Int = 3

/// Which intent head to run.
///
/// These are not interchangeable files — each is one leg of a TRIPLE that must
/// agree: CoreML head ↔ TF-IDF vocabulary ↔ calibration temperature. iOS builds
/// the feature vector in Swift from the weights JSON, so a head expecting 4718
/// features cannot be driven by a 1317-entry vocab, and each head has its own
/// fitted temperature. Mixing legs produces a shape mismatch at best and
/// plausible-looking wrong confidences at worst, which is why `resolveClassifier`
/// binds all three together or throws.
enum ClassifierVariant: String, Sendable, CaseIterable {
    /// RFE-pruned, ~1317 features. Smaller, 1.63pp less accurate.
    case pruned

    /// Full vocabulary, ~4718 features. **The default.**
    ///
    /// 90.20% vs 88.57% on the honest holdout (n=1470). Costs ~2.4 MB more than
    /// the pruned head *inside the pack* — but a pack ships both, so selecting
    /// it adds nothing to the download. If a deployment settles on one variant,
    /// the saving is in dropping the other from the pack, not in choosing here.
    ///
    /// ADR-017's `.cpuOnly` pinning holds at this size and is in fact better
    /// evidenced here: its load-cost (§4) and memory (§5) tables were measured
    /// on the FULL head — 15.6 ms load and 3.69 MB footprint on `.cpuOnly`
    /// versus 93.7 ms and 5.38 MB on `.all`. Its "planner flipped CPU→ANE
    /// between 1317 and 4718" note refers to Architecture B (`mlprogram`/FP16);
    /// Architecture A, which we ship, stays on CPU at both sizes.
    case full

    /// Base name of the weights file carrying this variant's vocab and idf.
    var weightsFileStem: String {
        switch self {
        case .pruned: return "intent_classifier_weights"
        case .full:   return "intent_classifier_weights_full"
        }
    }

    /// Key in `calibration.json` holding this variant's fitted temperature.
    var temperatureKey: String {
        switch self {
        case .pruned: return "temperature_coreml"
        case .full:   return "temperature_coreml_full"
        }
    }
}

struct NLUBundle: Decodable, Sendable, Equatable {

    let bundleID: String
    /// The pack's semantic version, as the compiler wrote it.
    ///
    /// Required, matching `NLUPackManifest` — which decodes this same `bundle.json`
    /// on the OTA path and has always required it. One file should not have two
    /// models that disagree about whether a field exists.
    ///
    /// `nlu_compiler` emits it from the same variable that builds `bundle_id`
    /// (`content_bundle.py`: `"bundle_id": f"pack-{lang}-v{version}"` / `"version": version`),
    /// so the two cannot disagree in real output, and it lands inside the bytes the
    /// Ed25519 signature covers.
    ///
    /// Never parsed out of `bundleID`. A pack that lacks the field is one built
    /// before that compiler change, and decoding fails loudly — which is the point.
    /// The alternative, which the host app used to do, was to patch the field in
    /// after extraction and thereby invalidate the signature.
    let version: String
    let formatVersion: String
    let contentVersion: Int
    let compilerVersion: String
    let channel: String
    let createdAt: String
    let checksumsRoot: String
    let telemetrySchemaVersion: Int
    let engineCompat: EngineCompat
    let requiredRuntimeFeatures: [String]
    let languages: [String: LanguageEntry]
    let capabilities: [String: CapabilityEntry]
    let models: ModelCatalog
    let signatureInfo: SignatureInfo
    let reportCardSummary: [String: ReportValue]

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case version
        case formatVersion = "format_version"
        case contentVersion = "content_version"
        case compilerVersion = "compiler_version"
        case channel
        case createdAt = "created_at"
        case checksumsRoot = "checksums_root"
        case telemetrySchemaVersion = "telemetry_schema_version"
        case engineCompat = "engine_compat"
        case requiredRuntimeFeatures = "required_runtime_features"
        case languages, capabilities, models
        case signatureInfo = "signature_info"
        case reportCardSummary = "report_card_summary"
    }

    // MARK: - Nested

    struct EngineCompat: Decodable, Sendable, Equatable {
        let minRuntimeContract: Int
        let maxTestedRuntimeContract: Int

        enum CodingKeys: String, CodingKey {
            case minRuntimeContract = "min_runtime_contract"
            case maxTestedRuntimeContract = "max_tested_runtime_contract"
        }

        /// `maxTested` is advisory, not a ceiling: a newer runtime reading an
        /// older pack is the normal upgrade path and must not be refused. Only
        /// the floor is binding.
        func admits(_ contract: Int) -> Bool { contract >= minRuntimeContract }
    }

    struct LanguageEntry: Decodable, Sendable, Equatable {
        /// "full" today. Unknown values are carried, not rejected — the loader
        /// decides what to do with a partial language.
        let status: String
    }

    struct CapabilityEntry: Decodable, Sendable, Equatable {
        let status: String
        let version: String
    }

    struct SignatureInfo: Decodable, Sendable, Equatable {
        let scheme: String
        let keyID: String

        enum CodingKeys: String, CodingKey {
            case scheme
            case keyID = "key_id"
        }
    }

    // MARK: - Models

    struct ModelCatalog: Decodable, Sendable, Equatable {
        /// Keyed by family ("intent", "semantic_head"), then by scope — a
        /// language code, or the literal "shared".
        let families: [String: [String: ModelSpec]]

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            families = try c.decode([String: [String: ModelSpec]].self)
        }

        func spec(family: String, scope: String) -> ModelSpec? {
            families[family]?[scope]
        }
    }

    /// One model's artifacts. Every path is pack-relative.
    ///
    /// iOS reads `coremlCompiledArtifact` first: a `.mlmodelc` is device-agnostic
    /// Espresso IR, so a CI-compiled artifact is portable and needs no
    /// on-device compilation (ADR-017 in the compiler repo). `MLModel(contentsOf:)`
    /// REQUIRES `.mlmodelc` and `compileModel(at:)` REJECTS one, so the choice
    /// of key decides which API is legal — the caller must dispatch on it.
    struct ModelSpec: Decodable, Sendable, Equatable {
        let artifact: String
        let format: String
        let modelVersion: String
        let coremlArtifact: String?
        let coremlCompiledArtifact: String?
        let coremlFullArtifact: String?
        let coremlFullCompiledArtifact: String?
        let tfliteArtifact: String?
        let tfliteInt8Artifact: String?
        let embedderID: String?

        enum CodingKeys: String, CodingKey {
            case artifact, format
            case modelVersion = "model_version"
            case coremlArtifact = "coreml_artifact"
            case coremlCompiledArtifact = "coreml_compiled_artifact"
            case coremlFullArtifact = "coreml_full_artifact"
            case coremlFullCompiledArtifact = "coreml_full_compiled_artifact"
            case tfliteArtifact = "tflite_artifact"
            case tfliteInt8Artifact = "tflite_int8_artifact"
            case embedderID = "embedder_id"
        }

        /// Every artifact path this spec declares, for existence checking.
        var declaredPaths: [String] {
            [artifact, coremlArtifact, coremlCompiledArtifact, coremlFullArtifact,
             coremlFullCompiledArtifact, tfliteArtifact, tfliteInt8Artifact].compactMap { $0 }
        }

        /// The artifact iOS should load for a variant, and whether it is
        /// already compiled. Compiled beats packaged: no on-device compile, no
        /// cache to manage, no invalidation to get wrong.
        func iOSModel(_ variant: ClassifierVariant) -> (path: String, isCompiled: Bool)? {
            switch variant {
            case .pruned:
                if let c = coremlCompiledArtifact { return (c, true) }
                if let p = coremlArtifact { return (p, false) }
            case .full:
                if let c = coremlFullCompiledArtifact { return (c, true) }
                if let p = coremlFullArtifact { return (p, false) }
            }
            return nil
        }
    }

    /// `report_card_summary` mixes numbers and stringified booleans
    /// (`gates_passed` is `"true"`, because the schema admits only
    /// number/string/integer). Model that honestly rather than forcing a type.
    enum ReportValue: Decodable, Sendable, Equatable {
        case string(String)
        case number(Double)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let d = try? c.decode(Double.self) { self = .number(d); return }
            self = .string(try c.decode(String.self))
        }

        var doubleValue: Double? {
            if case .number(let d) = self { return d }
            if case .string(let s) = self { return Double(s) }
            return nil
        }

        var boolValue: Bool? {
            if case .string(let s) = self { return Bool(s.lowercased()) }
            return nil
        }
    }
}

// MARK: - Derived

extension NLUBundle {

    var formatMajor: Int {
        let parts: [Substring] = formatVersion.split(separator: ".")
        guard let head: Substring = parts.first, let major = Int(head) else { return -1 }
        return major
    }

    var availableLanguages: [String] { languages.keys.sorted() }

    /// True for a pack signed with the committed development key or published
    /// on a non-production channel. ADR-005 Part 11 requires a production
    /// runtime to refuse both.
    var isDevelopmentPack: Bool {
        channel != "production" || signatureInfo.keyID == "dev-key-golden"
    }

    var gatesPassed: Bool? { reportCardSummary["gates_passed"]?.boolValue }

    /// Compatibility checks, in the order a loader should apply them. Returns
    /// nil when the pack is admissible.
    func compatibilityFailure(runtimeContract: Int = VIKRuntimeContract,
                                     supportedFeatures: Set<String>) -> VoiceIntentError? {
        guard formatMajor == VIKSupportedFormatMajor else {
            return .unsupportedFormatVersion(found: formatVersion,
                                             supportedMajor: VIKSupportedFormatMajor)
        }
        guard engineCompat.admits(runtimeContract) else {
            return .runtimeContractUnsupported(packMin: engineCompat.minRuntimeContract,
                                               packMaxTested: engineCompat.maxTestedRuntimeContract,
                                               ours: runtimeContract)
        }
        let unknown = requiredRuntimeFeatures.filter { !supportedFeatures.contains($0) }
        guard unknown.isEmpty else { return .unsupportedRuntimeFeatures(unknown.sorted()) }
        return nil
    }
}
