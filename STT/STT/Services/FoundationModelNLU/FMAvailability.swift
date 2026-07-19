// FMAvailability.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// Wraps SystemLanguageModel availability so the rest of the FM sample (and the
// landing screen) never touches the FoundationModels API directly. The landing
// screen shows the FM option disabled-with-reason on ineligible hardware
// rather than hiding it — an evaluator with an old phone should see *why*.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// App-facing availability verdict for the on-device Foundation Model.
///
/// Plain enum (not the framework type) so callers — including the always-compiled
/// landing screen — can consume it without `#if canImport(FoundationModels)`.
enum FMAvailabilityStatus: Equatable {
    /// Model is ready; the FM option can launch.
    case available
    /// Hardware lacks Apple Intelligence support (pre-A17 Pro / pre-M1).
    case deviceNotEligible
    /// Supported device, but Apple Intelligence is switched off in Settings.
    case appleIntelligenceNotEnabled
    /// Model assets still downloading; retry later.
    case modelNotReady
    /// Framework not linked / OS below iOS 26 / unknown future reason.
    case unsupported

    var isAvailable: Bool { self == .available }

    /// One-line, user-facing explanation for the disabled state.
    var userMessage: String {
        switch self {
        case .available:
            return "Apple on-device model ready"
        case .deviceNotEligible:
            return "Requires an Apple Intelligence-capable device (iPhone 15 Pro or later)"
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to enable this mode"
        case .modelNotReady:
            return "Apple Intelligence model is still downloading — try again shortly"
        case .unsupported:
            return "Foundation Models framework unavailable on this OS"
        }
    }
}

enum FMAvailability {
    /// Current availability. Safe to call from any context; cheap enough to call
    /// per-render (the framework exposes a simple property, no I/O).
    static func status() -> FMAvailabilityStatus {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:            return .deviceNotEligible
                case .appleIntelligenceNotEnabled:  return .appleIntelligenceNotEnabled
                case .modelNotReady:                return .modelNotReady
                @unknown default:                   return .unsupported
                }
            @unknown default:
                return .unsupported
            }
        }
        return .unsupported
        #else
        return .unsupported
        #endif
    }
}
