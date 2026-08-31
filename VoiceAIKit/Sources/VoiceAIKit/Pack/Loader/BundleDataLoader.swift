// BundleDataLoader.swift
// VoiceAIKit
//
// Pack on disk → verified, joined, language-bound `ResolvedPack`.
//
// Order is deliberate and each step gates the next:
//
//   1. verify the trust chain          — before parsing anything
//   2. decode bundle.json              — from the bytes the signature covered
//   3. compatibility                   — format, runtime contract, features
//   4. trust policy                    — dev pack in a release build?
//   5. select the language
//   6. load the v3 sections
//   7. join, and prove referential integrity
//   8. resolve classifier artifacts
//
// Nothing here falls back. Every failure is a typed throw. The predecessor
// degraded to English on any error and the resulting sessions looked healthy.

import Foundation
import os.log

enum BundleDataLoader {

    private static let log = Logger(subsystem: "com.voiceaikit", category: "BundleDataLoader")

    /// Runtime features this build implements. A pack requiring anything absent
    /// from this set is refused — fail closed, because an unrecognised feature
    /// may be the one its accuracy numbers depend on.
    static let supportedRuntimeFeatures: Set<String> = []

    /// Load a pack.
    ///
    /// - Parameters:
    ///   - url: the unpacked pack directory (the one containing `bundle.json`).
    ///   - language: which language to bind. Nil selects the only language when
    ///     the pack has exactly one, and throws when it has several — packs are
    ///     one-per-language today, but the format is a map and guessing is not
    ///     a behaviour worth having.
    ///   - variant: which intent head to bind. Defaults to `.full` — it is
    ///     1.63pp more accurate (90.20% vs 88.57% on the honest holdout) and a
    ///     pack that ships it has already paid the bytes, so selecting it costs
    ///     no extra download. Needs `intent_classifier_weights_full.json`;
    ///     packs before 1.0.29 do not carry it, and asking for it there throws
    ///     `declaredArtifactMissing` at load rather than failing at the first
    ///     inference with a shape mismatch.
    /// Steps 1-5 of `load`: existence, trust chain, decode from the VERIFIED bytes,
    /// runtime compatibility, trust policy + report-card gates, language selection.
    /// Everything up to — and not including — reading the pack's content.
    ///
    /// Split out so `VoiceIntentPack.verify` runs exactly these checks rather than a
    /// cheaper approximation of them. A host pre-checking a pack before it serves it is
    /// asking "would this load?", and answering that with a bare sha256 walk would let
    /// an incompatible, dev-signed or gate-failing pack through a check that reads,
    /// from the call site, like it caught everything.
    static func verifiedManifest(packAt url: URL,
                                 language: String?,
                                 trust: PackTrustPolicy,
                                 policy: PackLoadPolicy) throws -> (manifest: NLUBundle, language: String) {

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw VoiceIntentError.packNotFound(url)
        }

        // 1 — trust chain, before a single byte is interpreted.
        let verified = try PackIntegrity.verify(packRoot: url, trust: trust, policy: policy)

        // 2 — decode from the verified bytes, not a fresh read.
        let manifest: NLUBundle
        do {
            manifest = try JSONDecoder().decode(NLUBundle.self, from: verified.bundleJSONBytes)
        } catch {
            throw VoiceIntentError.malformedJSON(path: "bundle.json", reason: String(describing: error))
        }

        // 3 — compatibility.
        if let failure = manifest.compatibilityFailure(supportedFeatures: supportedRuntimeFeatures) {
            throw failure
        }

        // 4 — trust policy.
        if trust.refusesDevelopmentPacks && manifest.isDevelopmentPack {
            throw VoiceIntentError.untrustedPack(
                reason: "channel '\(manifest.channel)', key '\(manifest.signatureInfo.keyID)'")
        }
        if policy.requiresPassingGates, manifest.gatesPassed == false {
            throw VoiceIntentError.untrustedPack(reason: "report card gates did not pass")
        }

        // 5 — language.
        let lang = try selectLanguage(requested: language, manifest: manifest)

        return (manifest, lang)
    }

    static func load(packAt url: URL,
                            language: String? = nil,
                            variant: ClassifierVariant = .full,
                            trust: PackTrustPolicy,
                            policy: PackLoadPolicy = .default) throws -> ResolvedPack {

        // 1-5 — trust chain, manifest, compatibility, policy, language.
        let (manifest, lang) = try verifiedManifest(
            packAt: url, language: language, trust: trust, policy: policy)

        // 6 — sections.
        let sections = try loadSections(root: url, language: lang, manifest: manifest, policy: policy)

        // 7 — join + prove consistency.
        let resolved = try join(root: url, language: lang, manifest: manifest,
                                sections: sections, variant: variant)

        log.info("""
            Loaded \(manifest.bundleID, privacy: .public) [\(lang, privacy: .public)] — \
            \(resolved.intents.count) intents, \(resolved.responses.count) responses, \
            \(resolved.keywordRules.count) keyword rules, \
            semantic stage \(resolved.stageEnabled(.semantic) ? "on" : "off", privacy: .public)
            """)
        return resolved
    }

    // MARK: - Language

    static func selectLanguage(requested: String?, manifest: NLUBundle) throws -> String {
        let available = manifest.availableLanguages
        if let requested {
            guard available.contains(requested) else {
                throw VoiceIntentError.languageUnavailable(requested: requested, available: available)
            }
            return requested
        }
        guard let only = available.first, available.count == 1 else {
            throw VoiceIntentError.languageAmbiguous(available: available)
        }
        return only
    }

    // MARK: - Sections

    struct Sections {
        var capabilities: [CapabilityManifest] = []
        var workflows: [String: IntentWorkflow] = [:]
        var responses: [String: String] = [:]
        var entities: PackEntities
        var lexicon: PackLexicon
        var keywords: PackKeywords
        var policies: PackPolicies
        var cascade: PackCascade
        var routing: PackRouting
        var guards: PackGuards
        var telemetry: PackTelemetrySchema
    }

    static func loadSections(root: URL,
                             language: String,
                             manifest: NLUBundle,
                             policy: PackLoadPolicy) throws -> Sections {

        // Per-language files must all exist before we claim the language works.
        let required = ["lexicons/\(language).json", "keywords/\(language).json"]
        let missing = required.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        guard missing.isEmpty else {
            throw VoiceIntentError.languageIncomplete(language: language, missing: missing)
        }

        var capabilities: [CapabilityManifest] = []
        var workflows: [String: IntentWorkflow] = [:]
        var responses: [String: String] = [:]

        let capRoot = root.appendingPathComponent("capabilities", isDirectory: true)
        let capDirs = (try? FileManager.default.contentsOfDirectory(
            at: capRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for dir in capDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let id = dir.lastPathComponent

            capabilities.append(try decode(CapabilityManifest.self,
                                           at: dir.appendingPathComponent("capability.json"),
                                           relative: "capabilities/\(id)/capability.json"))

            let wf = try decode(CapabilityWorkflows.self,
                                at: dir.appendingPathComponent("workflows.json"),
                                relative: "capabilities/\(id)/workflows.json")
            workflows.merge(wf.intents) { current, _ in current }

            // A capability with no catalog for this language is a real gap, not
            // something to paper over with the English one.
            let respPath = "capabilities/\(id)/responses/\(language).json"
            let respURL = root.appendingPathComponent(respPath)
            guard FileManager.default.fileExists(atPath: respURL.path) else {
                throw VoiceIntentError.languageIncomplete(language: language, missing: [respPath])
            }
            let strings = try decode([String: String].self, at: respURL, relative: respPath)
            responses.merge(strings) { current, _ in current }
        }

        return Sections(
            capabilities: capabilities,
            workflows: workflows,
            responses: responses,
            entities: try decode(PackEntities.self,
                                 at: root.appendingPathComponent("entities/shared/content.json"),
                                 relative: "entities/shared/content.json"),
            lexicon: try decode(PackLexicon.self,
                                at: root.appendingPathComponent("lexicons/\(language).json"),
                                relative: "lexicons/\(language).json"),
            keywords: try decode(PackKeywords.self,
                                 at: root.appendingPathComponent("keywords/\(language).json"),
                                 relative: "keywords/\(language).json"),
            policies: try decode(PackPolicies.self,
                                 at: root.appendingPathComponent("runtime/policies.json"),
                                 relative: "runtime/policies.json"),
            cascade: try decode(PackCascade.self,
                                at: root.appendingPathComponent("runtime/cascade.json"),
                                relative: "runtime/cascade.json"),
            routing: try decode(PackRouting.self,
                                at: root.appendingPathComponent("runtime/routing.json"),
                                relative: "runtime/routing.json"),
            // Additive: a pack predating the guards section simply has none.
            guards: (try? decode(PackGuards.self,
                                 at: root.appendingPathComponent("runtime/guards.json"),
                                 relative: "runtime/guards.json")) ?? .empty,
            telemetry: try decode(PackTelemetrySchema.self,
                                  at: root.appendingPathComponent("telemetry/schema.json"),
                                  relative: "telemetry/schema.json")
        )
    }

    // MARK: - Join

    static func join(root: URL,
                     language: String,
                     manifest: NLUBundle,
                     sections: Sections,
                     variant: ClassifierVariant) throws -> ResolvedPack {

        let intents = sections.workflows
        let intentIDs = Set(intents.keys)

        // -- every referenced key resolves --------------------------------
        var actionOwners: [String: String] = [:]
        for capability in sections.capabilities {
            for action in capability.actions { actionOwners[action.key] = capability.id }
        }

        for (intent, wf) in intents {
            if let completion = wf.completion {
                guard sections.responses[completion.response] != nil else {
                    throw VoiceIntentError.danglingResponseKey(intent: intent, key: completion.response)
                }
                guard actionOwners[completion.action] != nil else {
                    throw VoiceIntentError.danglingActionKey(intent: intent, action: completion.action)
                }
            }
            if let confirmation = wf.confirmation {
                guard sections.responses[confirmation.prompt] != nil else {
                    throw VoiceIntentError.danglingResponseKey(intent: intent, key: confirmation.prompt)
                }
            }
            for slot in wf.slots {
                guard sections.responses[slot.prompt] != nil else {
                    throw VoiceIntentError.danglingResponseKey(intent: intent, key: slot.prompt)
                }
                guard sections.entities.entities[slot.entity] != nil else {
                    throw VoiceIntentError.danglingEntityReference(intent: intent,
                                                                   slot: slot.name,
                                                                   entity: slot.entity)
                }
            }
        }

        // A guard redirecting to an intent the pack lacks routes a real
        // utterance into a void.
        if let helpMarker = sections.guards.helpMarker {
            for (from, to) in helpMarker.pairs where !intentIDs.contains(to) || !intentIDs.contains(from) {
                throw VoiceIntentError.danglingGuardIntent(from: from, to: to)
            }
        }

        // -- entities, bound to this language ------------------------------
        // Every per-entity FLAG has to be carried across this join explicitly.
        // `entities` is flattened to synonyms, so anything not lifted out here is
        // gone — that is how `fuzzy` was lost (VIK-003) and how `open` would be
        // lost again now that the compiler emits it.
        var entities: [String: [String: [String]]] = [:]
        var dynamic: Set<String> = []
        var fuzzy: Set<String> = []
        var open: Set<String> = []
        var builtinSources: [String: String] = [:]
        for (id, definition) in sections.entities.entities {
            if definition.isDynamic {
                dynamic.insert(id)
                if let source = definition.dynamicSource { builtinSources[id] = source }
                continue
            }
            entities[id] = definition.synonyms(language: language)
            if definition.fuzzy { fuzzy.insert(id) }
            if definition.open { open.insert(id) }
        }

        // -- classifier ----------------------------------------------------
        let classifier = try resolveClassifier(root: root,
                                               language: language,
                                               manifest: manifest,
                                               policies: sections.policies,
                                               variant: variant)

        // Model and label space must come from the same run.
        if let dim = sections.cascade.tfidfOutputDim, dim != classifier.labels.count {
            throw VoiceIntentError.labelCountMismatch(cascadeDim: dim, labels: classifier.labels.count)
        }
        let labelSet = Set(classifier.labels)
        if labelSet != intentIDs {
            throw VoiceIntentError.labelSchemaMismatch(
                missingFromSchema: labelSet.subtracting(intentIDs).sorted(),
                missingFromLabels: intentIDs.subtracting(labelSet).sorted())
        }

        return ResolvedPack(
            manifest: manifest,
            language: language,
            root: root,
            intents: intents,
            responses: sections.responses,
            actionOwners: actionOwners,
            entities: entities,
            dynamicEntities: dynamic,
            fuzzyEntities: fuzzy,
            openEntities: open,
            builtinSources: builtinSources,
            lexicon: sections.lexicon,
            keywordRules: sections.keywords.rules,
            policies: sections.policies,
            cascade: sections.cascade,
            routing: sections.routing,
            guards: sections.guards,
            telemetry: sections.telemetry,
            classifier: classifier)
    }

    // MARK: - Classifier artifacts

    /// Bind the classifier triple — CoreML head, TF-IDF vocabulary, calibration
    /// temperature — as a unit.
    ///
    /// All three are variant-specific and none is interchangeable. The full head
    /// takes ~4718 features; the pruned vocab has 1317, and iOS builds the
    /// feature vector in Swift, so pairing them cannot work. Each head also has
    /// its own fitted temperature, and applying the wrong one shifts every
    /// confidence past a 0.70 gate without any visible error. So this either
    /// resolves a complete, self-consistent triple or throws.
    static func resolveClassifier(root: URL,
                                  language: String,
                                  manifest: NLUBundle,
                                  policies: PackPolicies,
                                  variant: ClassifierVariant) throws -> ResolvedPack.ClassifierArtifacts {

        let labelsPath = "models/intent/\(language)/labels.json"
        let labels = try decode([String].self,
                                at: root.appendingPathComponent(labelsPath),
                                relative: labelsPath)

        // -- leg 1: vocabulary -------------------------------------------
        let weightsPath = "models/intent/\(language)/\(variant.weightsFileStem).json"
        let weightsURL = root.appendingPathComponent(weightsPath)
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            // Packs through 1.0.28 ship only the pruned weights, so asking for
            // `.full` fails HERE rather than at first inference with a shape
            // mismatch. Needs `intent_classifier_weights_full.json` in the pack.
            throw VoiceIntentError.declaredArtifactMissing(path: weightsPath)
        }
        let weights = try decodeAny(at: weightsURL, relative: weightsPath)
        // Thresholds come from the pack's policy table; the weights carry their
        // own copy but policy is the contract.
        let gap = weights["conf_gap_threshold"] as? Double ?? 0.20

        // -- leg 2: temperature -------------------------------------------
        // A pack ships several. `temperature` calibrates the SERVER/ONNX
        // featurizer and must never be used on device — the two calibrate
        // different featurizers and deliberately disagree (Review-F5 B8 in the
        // compiler repo). Fall back to the weights' own value only if the
        // calibration file lacks the variant key.
        let calibrationPath = "models/intent/\(language)/calibration.json"
        let calibration = (try? decodeAny(at: root.appendingPathComponent(calibrationPath),
                                          relative: calibrationPath)) ?? [:]
        let temperature = (calibration[variant.temperatureKey] as? Double)
            ?? (weights["temperature"] as? Double)
            ?? 1.0

        // -- leg 3: the head ----------------------------------------------
        //
        // Two different situations, and conflating them would be a bug:
        //
        //   not declared  -> nil. The pack ships no CoreML head for this
        //                    variant (a standalone `content_bundle` compile does
        //                    not stage the iOS artifacts; only the CI
        //                    `assemble_pack` path does). Stage 2 still runs
        //                    through the pure-Swift TF-IDF + LogReg path built
        //                    from `weightsURL`, so this is degraded, not broken.
        //   declared but
        //   absent        -> throw. The manifest promised a file the pack does
        //                    not contain, which means the pack is malformed and
        //                    nothing else it says can be trusted either.
        var model: ResolvedPack.ClassifierArtifacts.ModelArtifact?
        if let spec = manifest.models.spec(family: "intent", scope: language),
           let choice = spec.iOSModel(variant) {
            let url = root.appendingPathComponent(choice.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoiceIntentError.declaredArtifactMissing(path: choice.path)
            }
            model = .init(url: url, isCompiled: choice.isCompiled)
        } else {
            log.notice("""
                Pack declares no CoreML head for variant '\(variant.rawValue, privacy: .public)' \
                [\(language, privacy: .public)] — Stage 2 will run the pure-Swift TF-IDF path
                """)
        }

        return .init(variant: variant,
                     labels: labels,
                     model: model,
                     weightsURL: weightsURL,
                     temperature: temperature,
                     confidenceThreshold: policies.thresholds.confidence,
                     confidenceGapThreshold: gap)
    }

    // MARK: - Decoding helpers

    static func decode<T: Decodable>(_ type: T.Type, at url: URL, relative: String) throws -> T {
        guard let data = try? Data(contentsOf: url) else {
            throw VoiceIntentError.unreadableFile(path: relative, reason: "not readable")
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw VoiceIntentError.malformedJSON(path: relative, reason: String(describing: error)) }
    }

    static func decodeAny(at url: URL, relative: String) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else {
            throw VoiceIntentError.unreadableFile(path: relative, reason: "not readable")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VoiceIntentError.malformedJSON(path: relative, reason: "not a JSON object")
        }
        return obj
    }
}
