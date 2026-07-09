// CoreMLClassifierBackend.swift
// IntentKitCoreML
//
// The ONLY stage that touches Core ML. Maps an embedding to raw logits over the
// intent label set. Runs on the Neural Engine / GPU when available (.all).
//
// NOTE: This is a reference scaffold. Wire `predict` to your compiled `MLModel`'s
// generated interface (input: MLMultiArray embedding → output: logits array).

import Foundation
import CoreML
import IntentKitCore

public final class CoreMLClassifierBackend: IntentClassifierBackend, @unchecked Sendable {

    public let labels: [Intent]
    private let model: MLModel
    private let inputName: String
    private let outputName: String

    /// - Parameters:
    ///   - modelURL: Compiled `.mlmodelc` URL.
    ///   - labels: Ordered label set — index i corresponds to output logit i.
    ///   - inputName / outputName: Feature names in the model interface.
    public init(
        modelURL: URL,
        labels: [Intent],
        inputName: String = "embedding",
        outputName: String = "logits"
    ) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all              // Neural Engine / GPU / CPU — the key Core ML advantage.
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
        self.labels = labels
        self.inputName = inputName
        self.outputName = outputName
    }

    public func predict(_ embedding: Embedding) async throws -> [IntentLogit] {
        let array = try MLMultiArray(shape: [NSNumber(value: embedding.dimension)], dataType: .float32)
        for (i, v) in embedding.values.enumerated() { array[i] = NSNumber(value: v) }

        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        let out = try model.prediction(from: provider)

        guard let logits = out.featureValue(for: outputName)?.multiArrayValue else {
            throw IntentKitError.modelNotFound(outputName)
        }
        guard logits.count == labels.count else {
            throw IntentKitError.labelSchemaMismatch(expected: labels.count, actual: logits.count)
        }
        return (0..<labels.count).map { i in
            IntentLogit(intent: labels[i], score: logits[i].doubleValue)
        }
    }
}
