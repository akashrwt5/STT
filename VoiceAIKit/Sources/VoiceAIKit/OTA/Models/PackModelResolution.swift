// PackModelResolution.swift
// VoiceAIKit
//
// Resolving a model's on-disk paths from the pack's own manifest.
//
// This file used to hold `NLUPackManifest` — a SECOND `Decodable` model of
// `bundle.json`, alongside `NLUBundle` in `Pack/Schema/`. The two read different
// subsets of the same file and disagreed about what was in it: `NLUBundle`
// carried `channel`, `compiler_version`, `required_runtime_features` and
// `telemetry_schema_version`; `NLUPackManifest` carried none of them. (VIK-034.)
//
// That was not a tidiness problem. `PackTrustPolicy.refusesDevelopmentPacks` is
// enforced by asking the manifest for its `channel` — and the OTA installer,
// which decoded the model that had no `channel`, could not ask. So a dev-channel
// pack was downloaded, verified, staged and ACTIVATED, and the refusal landed
// later, when a session tried to load it: the most expensive place to say no.
//
// There is now one model. `NLUBundle` decodes `bundle.json`, once, from the
// bytes the signature covers. `PackIdentity` is what hosts see. What remains
// here is the part that was never about decoding — turning a decoded manifest
// into file URLs.

import Foundation

/// Resolved paths for a model's CoreML and vocabulary artifacts.
struct ModelResolution {
    let modelURL: URL
    let vocabularyURL: URL
}

/// Errors thrown when resolving model paths from a manifest.
enum ModelResolutionError: Error, LocalizedError {
    case missingModelInfo(component: String, language: String)
    case missingCoreMLArtifact(component: String)

    var errorDescription: String? {
        switch self {
        case .missingModelInfo(let component, let lang):
            return "Manifest missing '\(component)' model definition for language '\(lang)'."
        case .missingCoreMLArtifact(let component):
            return "Manifest missing compiled CoreML artifact for '\(component)'. ONNX is strictly disabled."
        }
    }
}

extension NLUBundle {

    /// The model component the OTA activation path loads and smoke-tests. Kept as a named constant
    /// rather than a literal so adding a second head (e.g. `"semantic_head"`) is an additive change
    /// — call `resolveModelPaths(for:component:relativeTo:)` with the new name — not an edit to the
    /// resolution logic (Open/Closed).
    static let primaryModelComponent = "intent"

    /// Resolves the primary (`intent`) CoreML model and vocabulary file paths from this manifest.
    func resolveModelPaths(for language: String, relativeTo baseURL: URL) throws -> ModelResolution {
        try resolveModelPaths(for: language, component: Self.primaryModelComponent, relativeTo: baseURL)
    }

    /// Resolves the CoreML model and vocabulary file paths for an arbitrary model component.
    ///
    /// NOTE — this returns the PRUNED head (`coreml_compiled_artifact`), while a live
    /// `VoiceIntentSession` defaults to `.full` via `ModelSpec.iOSModel(_:)`. The two paths have
    /// disagreed about which head to load since before this refactor; it is left as-is here
    /// deliberately, because changing which model `VoiceIntentClient` hands the engine is a
    /// behavioural change and does not belong in a de-duplication. Tracked separately.
    ///
    /// - Parameters:
    ///   - language: The language code (e.g. "en"). Falls back to the `"shared"` scope.
    ///
    /// The fallback scope changed from `"default"` to `"shared"` here. `"default"` was dead:
    /// `modelLangMap` in the v3 schema keys model scopes by `^([a-z]{2}|shared)$`, so no pack
    /// can carry a `"default"` entry and the fallback could only ever fail. `"shared"` is the
    /// scope the format actually defines, and the one `models.semantic_head` uses today.
    /// Neither branch is reachable for the only component this is called with (`intent`, which
    /// is always keyed by language), so this changes no behaviour in any pack that exists.
    ///   - component: The model component to resolve (e.g. "intent", "semantic_head").
    ///   - baseURL: The root directory of the extracted pack.
    func resolveModelPaths(for language: String,
                           component: String,
                           relativeTo baseURL: URL) throws -> ModelResolution {
        guard let spec = models.spec(family: component, scope: language)
                ?? models.spec(family: component, scope: "shared") else {
            throw ModelResolutionError.missingModelInfo(component: component, language: language)
        }

        // Enforce CoreML usage (ONNX is strictly disabled on iOS).
        guard let artifactPath = spec.coremlCompiledArtifact else {
            throw ModelResolutionError.missingCoreMLArtifact(component: component)
        }

        let modelURL = baseURL.appendingPathComponent(artifactPath)

        // The vocabulary is always the `vocab.txt` sibling of the model.
        //
        // The type this replaced declared a `vocabulary_artifact` key and preferred it when
        // present. It is never present: `spec/bundle/3.0/bundle.schema.json` sets
        // `additionalProperties: false` on the model entry and does not list the key, so a pack
        // that emitted it would fail its own schema. The branch was unreachable in every pack
        // that can exist, and is not carried forward — an unreachable preference reads as a
        // supported feature.
        let vocabURL = modelURL.deletingLastPathComponent().appendingPathComponent("vocab.txt")

        return ModelResolution(modelURL: modelURL, vocabularyURL: vocabURL)
    }
}
