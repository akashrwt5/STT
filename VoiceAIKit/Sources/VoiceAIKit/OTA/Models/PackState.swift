import Foundation

/// Represents the explicit lifecycle state of an NLU Pack during the OTA update process.
/// `Sendable` because it crosses an actor boundary: `NLUPackInstaller` is an
/// actor and `stagingState` is read from outside it (the installer's own tests
/// do, and so would any host observing progress). A `String`-raw-value enum with
/// no associated values is trivially sendable — the conformance was simply never
/// written, so strict concurrency refused every read of it.
public enum PackState: String, Codable, Equatable, Sendable {
    
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
