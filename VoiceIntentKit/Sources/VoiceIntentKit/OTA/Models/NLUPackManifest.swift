import Foundation

/// Represents the `bundle.json` schema of a downloaded NLU pack.
/// This acts as the single source of truth for validating an OTA package before installation.
public struct NLUPackManifest: Codable, Equatable {
    /// Unique identifier for this specific build of the NLU pack (e.g., "pack-en-v1.0.36").
    public let bundleId: String
    
    /// The semantic version of the package (e.g., "1.0.36").
    /// Used by the iOS SDK to name the installation directory.
    public let version: String
    
    /// The structural version of the `.nlu` package format (e.g., "3.0").
    /// Used to ensure the SDK knows how to unzip and read the directory layout.
    public let formatVersion: String
    
    /// The version of the NLU content itself (e.g., 1).
    public let contentVersion: Int
    
    /// Defines the minimum SDK requirements to safely run this model.
    public let engineCompat: EngineCompat
    
    /// The root cryptographic hash used to verify the integrity of the package contents.
    public let checksumsRoot: String
    
    /// Cryptographic signature metadata used to verify authenticity and prevent tampering.
    public let signatureInfo: SignatureInfo
    
    /// ISO8601 timestamp of when the compiler built this package.
    public let createdAt: String 
    
    /// Map of language codes (e.g., "en") to their deployment status.
    /// Used to quickly check if a downloaded pack supports the user's current locale.
    public let languages: [String: LanguageStatus]
    
    /// Nested dictionary defining the exact file paths for each model component.
    /// Component -> Locale/Variant -> Artifact Info.
    public let models: [String: [String: ModelArtifact]]
    
    /// Map of capabilities (e.g., "activity", "messaging.ptt") to their status and version.
    /// Allows the SDK to know which domains this specific model is trained to handle.
    public let capabilities: [String: CapabilityStatus]

    public enum CodingKeys: String, CodingKey {
        case bundleId = "bundle_id"
        case version
        case formatVersion = "format_version"
        case contentVersion = "content_version"
        case engineCompat = "engine_compat"
        case checksumsRoot = "checksums_root"
        case signatureInfo = "signature_info"
        case createdAt = "created_at"
        case languages
        case models
        case capabilities
    }
}

/// Enforces backward and forward compatibility between the OTA package and the VoiceIntentKit SDK.
/// If an OTA update contains a model that requires new ONNX operators or new tokenization logic,
/// the compiler bumps `minRuntimeContract`. The SDK checks this to avoid crashing on incompatible models.
public struct EngineCompat: Codable, Equatable {
    /// The minimum version of VoiceIntentKit's inference engine required to run this pack.
    public let minRuntimeContract: Int
    
    /// The highest version of the runtime engine that this pack was officially tested against.
    public let maxTestedRuntimeContract: Int?

    public enum CodingKeys: String, CodingKey {
        case minRuntimeContract = "min_runtime_contract"
        case maxTestedRuntimeContract = "max_tested_runtime_contract"
    }
}

/// Contains metadata required for cryptographic authenticity verification.
/// Prevents the SDK from loading a package that was intercepted or modified by a malicious third party.
public struct SignatureInfo: Codable, Equatable {
    /// The cryptographic algorithm used (e.g., "ed25519-v1").
    public let scheme: String
    
    /// Identifier for the public key that should be used to verify the signature (e.g., "dev-key-golden").
    public let keyId: String

    public enum CodingKeys: String, CodingKey {
        case scheme
        case keyId = "key_id"
    }
}

/// Represents the availability status of a specific language in the pack.
public struct LanguageStatus: Codable, Equatable {
    /// The readiness status (e.g., "full", "beta").
    public let status: String
}

/// Points to the exact file paths within the unzipped package for a specific model component.
/// This allows the backend to move or rename files in the future without breaking the SDK,
/// because the SDK relies on this manifest for paths instead of hardcoding them.
public struct ModelArtifact: Codable, Equatable {
    /// Path to the primary artifact (e.g., "models/intent/en/model.onnx").
    public let artifact: String
    
    /// Path to the vocabulary or lexicon file (e.g., "models/intent/en/vocab.txt").
    public let vocabularyArtifact: String?
    
    /// Path to the uncompiled CoreML package, if available.
    public let coremlArtifact: String?
    
    /// Path to the compiled CoreML model (`.mlmodelc`), optimized for Apple Neural Engine.
    public let coremlCompiledArtifact: String?
    
    /// Path to the full uncompiled CoreML package, if available.
    public let coremlFullArtifact: String?
    
    /// Path to the full compiled CoreML model (`.mlmodelc`).
    public let coremlFullCompiledArtifact: String?
    
    /// The format of the primary artifact (e.g., "onnx", "json").
    public let format: String
    
    /// The specific version of this individual model component (e.g., "en-1.0.36").
    public let modelVersion: String
    
    public enum CodingKeys: String, CodingKey {
        case artifact
        case vocabularyArtifact = "vocabulary_artifact"
        case coremlArtifact = "coreml_artifact"
        case coremlCompiledArtifact = "coreml_compiled_artifact"
        case coremlFullArtifact = "coreml_full_artifact"
        case coremlFullCompiledArtifact = "coreml_full_compiled_artifact"
        case format
        case modelVersion = "model_version"
    }
}

/// Defines a specific domain or capability that the model supports (e.g., "translation", "find").
/// Used by the Host Application to dynamically enable or disable features based on the loaded model.
public struct CapabilityStatus: Codable, Equatable {
    public let status: String
    public let version: String
}

// MARK: - Model Resolution

/// Resolved paths for a model's CoreML and vocabulary artifacts.
public struct ModelResolution {
    public let modelURL: URL
    public let vocabularyURL: URL
}

/// Errors thrown when resolving model paths from a manifest.
public enum ModelResolutionError: Error, LocalizedError {
    case missingModelInfo(component: String, language: String)
    case missingCoreMLArtifact(component: String)

    public var errorDescription: String? {
        switch self {
        case .missingModelInfo(let component, let lang):
            return "Manifest missing '\(component)' model definition for language '\(lang)'."
        case .missingCoreMLArtifact(let component):
            return "Manifest missing compiled CoreML artifact for '\(component)'. ONNX is strictly disabled."
        }
    }
}

extension NLUPackManifest {
    /// The model component the OTA activation path loads and smoke-tests. Kept as a named constant
    /// rather than a literal so adding a second head (e.g. `"semantic_head"`) is an additive change
    /// — call `resolveModelPaths(for:component:relativeTo:)` with the new name — not an edit to the
    /// resolution logic (Open/Closed).
    public static let primaryModelComponent = "intent"

    /// Resolves the primary (`intent`) CoreML model and vocabulary file paths from this manifest.
    public func resolveModelPaths(for language: String, relativeTo baseURL: URL) throws -> ModelResolution {
        try resolveModelPaths(for: language, component: Self.primaryModelComponent, relativeTo: baseURL)
    }

    /// Resolves the CoreML model and vocabulary file paths for an arbitrary model component.
    /// - Parameters:
    ///   - language: The language code (e.g. "en"). Falls back to the `"default"` variant.
    ///   - component: The model component to resolve (e.g. "intent", "semantic_head").
    ///   - baseURL: The root directory of the extracted pack.
    public func resolveModelPaths(for language: String,
                                  component: String,
                                  relativeTo baseURL: URL) throws -> ModelResolution {
        guard let modelInfo = models[component]?[language] ?? models[component]?["default"] else {
            throw ModelResolutionError.missingModelInfo(component: component, language: language)
        }

        // Enforce CoreML usage (ONNX is strictly disabled on iOS)
        guard let artifactPath = modelInfo.coremlCompiledArtifact else {
            throw ModelResolutionError.missingCoreMLArtifact(component: component)
        }

        let modelURL = baseURL.appendingPathComponent(artifactPath)
        let vocabURL: URL
        if let vocabPath = modelInfo.vocabularyArtifact {
            vocabURL = baseURL.appendingPathComponent(vocabPath)
        } else {
            vocabURL = modelURL.deletingLastPathComponent().appendingPathComponent("vocab.txt")
        }

        return ModelResolution(modelURL: modelURL, vocabularyURL: vocabURL)
    }
}
