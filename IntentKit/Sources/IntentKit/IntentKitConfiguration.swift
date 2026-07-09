// IntentKitConfiguration.swift
// IntentKit
//
// Declarative configuration for the common cases. Business thresholds live HERE,
// never hard-coded in the pipeline.

import Foundation
import IntentKitCore

public struct IntentKitConfiguration: Sendable {

    public enum ModelSource: Sendable {
        case bundled(name: String)      // compiled .mlmodelc in the app/package bundle
        case url(URL)                   // explicit compiled-model URL
    }

    public var model: ModelSource
    public var labels: [Intent]
    public var acceptThreshold: Double
    public var marginThreshold: Double
    public var maxEntropyRatio: Double
    public var softmaxTemperature: Double

    public init(
        model: ModelSource,
        labels: [Intent],
        acceptThreshold: Double = 0.6,
        marginThreshold: Double = 0.15,
        maxEntropyRatio: Double = 0.9,
        softmaxTemperature: Double = 1.0
    ) {
        self.model = model
        self.labels = labels
        self.acceptThreshold = acceptThreshold
        self.marginThreshold = marginThreshold
        self.maxEntropyRatio = maxEntropyRatio
        self.softmaxTemperature = softmaxTemperature
    }

    /// Convenience factory for the default Core ML + NaturalLanguage setup.
    public static func coreML(
        model: ModelSource,
        labels: [Intent],
        acceptThreshold: Double = 0.6,
        marginThreshold: Double = 0.15
    ) -> IntentKitConfiguration {
        IntentKitConfiguration(
            model: model,
            labels: labels,
            acceptThreshold: acceptThreshold,
            marginThreshold: marginThreshold
        )
    }
}
