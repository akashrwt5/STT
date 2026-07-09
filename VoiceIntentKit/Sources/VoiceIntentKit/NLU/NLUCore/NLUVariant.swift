// NLUVariant.swift
// STT
//
// Selectable NLU pipeline variant. Chosen at the View layer and threaded
// through PVAViewModel → factory → concrete classifier at construction time.
// Adding a variant is a new case here plus a new factory case in
// NLUEngineFactoryProvider — no edits to any service or engine type.

import Foundation

// MARK: - NLUVariant

/// Selectable NLU pipeline variant.
///
/// `RawValue` is `String` so `@AppStorage` can persist the selection directly
/// via its `RawRepresentable` conformance — no custom storage glue required.
public enum NLUVariant: String, CaseIterable, Identifiable {
    case english      = "english"
    case multilingual = "multilingual"

    public var id: String { rawValue }

    /// Human-facing label for the variant Picker.
    public var displayName: String {
        switch self {
        case .english:      return "English"
        case .multilingual: return "Multilingual"
        }
    }
}
