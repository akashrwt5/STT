// ClassifierBundle.swift
// VoiceIntentKit
//
// Descriptor consumed by IntentClassifierService. Names the CoreML model and
// pure-Swift weights JSON — the runtime code is identical across bundles.
//
// Decision thresholds (`conf` / `gap`) are NOT in this type. They travel via
// `IntentClassifierService.init(bundle:confThreshold:confGapThreshold:)` from
// the pack manifest, keeping model-loading and decision-policy concerns
// separate.
//
// Bundles are constructed from a `ClassifierSpec` inside a `LanguagePack`
// manifest — no static `.english` / `.multilingual` constants. Adding a
// language with its own dedicated model is a manifest change, not a Swift
// change.

import Foundation

public struct ClassifierBundle: Sendable {

    /// Base name (no extension) of the CoreML model in Bundle.module.
    /// Resolved as `<name>.mlmodelc` (Xcode-compiled) with `.mlpackage` fallback.
    public let modelResourceName: String

    /// Base name (no extension) of the pure-Swift weights JSON in Bundle.module.
    /// Must contain: `labels`, `vocab`, `idf`. Optional: `coef`, `intercept`,
    /// `temperature`, `conf_threshold`, `conf_gap_threshold`, `genai_base_url`.
    public let weightsResourceName: String

    /// os.log category. Distinct per bundle so Console.app can filter
    /// English vs multilingual vs future variants.
    public let loggerCategory: String

    public init(
        modelResourceName: String,
        weightsResourceName: String,
        loggerCategory: String
    ) {
        self.modelResourceName = modelResourceName
        self.weightsResourceName = weightsResourceName
        self.loggerCategory = loggerCategory
    }

    /// Build a bundle from a manifest-supplied `ClassifierSpec`. The primary
    /// entry point: every runtime bundle flows through here, so adding a
    /// language ⇒ authoring a spec, never a Swift edit.
    public init(spec: ClassifierSpec) {
        self.init(
            modelResourceName: spec.model,
            weightsResourceName: spec.weights,
            loggerCategory: spec.loggerCategory
        )
    }
}

