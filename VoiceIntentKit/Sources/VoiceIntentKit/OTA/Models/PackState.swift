import Foundation

/// Represents the explicit lifecycle state of an NLU Pack during the OTA update process.
public enum PackState: String, Codable, Equatable {
    
    /// The pack has been downloaded but not yet extracted or validated.
    case downloaded
    
    /// The pack is currently being validated (signatures, compatibility, structure).
    case validating
    
    /// The pack has been extracted, validated, and successfully smoke-tested. It is safe to activate.
    case readyToActivate
    
    /// The pack is currently the active model being used for inference.
    case active
    
    /// The pack failed validation, smoke testing, or activation.
    case failed
}
