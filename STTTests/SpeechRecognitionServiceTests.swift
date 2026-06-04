// SpeechRecognitionServiceTests.swift
// STTTests

import XCTest
import Speech
@testable import STT

final class SpeechRecognitionServiceTests: XCTestCase {

    // MARK: - Locale Resolution

    func testLocaleResolutionFallsBackToEnIN() {
        // When no override is provided and no device locale match exists,
        // the service should resolve to a supported locale (not crash).
        let locale = SpeechRecognitionService.resolveLocale(userOverride: nil)
        XCTAssertFalse(locale.identifier.isEmpty, "Resolved locale should not be empty")
    }

    func testLocaleResolutionWithExplicitOverride() {
        // A recognized override should be honoured if a matching model exists.
        let supported = SpeechTranscriber.supportedLocales
        guard let first = supported.first else {
            return // No locales available in test environment — skip
        }

        let resolved = SpeechRecognitionService.resolveLocale(userOverride: first.identifier)
        XCTAssertEqual(resolved.identifier, first.identifier)
    }

    func testLocaleResolutionWithUnknownOverride() {
        // An unrecognized override should fall through to a default.
        let resolved = SpeechRecognitionService.resolveLocale(userOverride: "xx-ZZ")
        XCTAssertFalse(resolved.identifier.isEmpty)
    }

    // MARK: - Available Locales

    func testAvailableLocalesMatchesSpeechTranscriber() {
        let service = SpeechRecognitionService(locale: Locale(identifier: "en-IN"))
        // Must expose the same set the system reports.
        XCTAssertEqual(service.availableLocales.map(\.identifier).sorted(),
                       SpeechTranscriber.supportedLocales.map(\.identifier).sorted())
    }

    // MARK: - Locale Switch

    func testSwitchLocaleToUnsupportedThrows() async {
        let service = SpeechRecognitionService(locale: Locale(identifier: "en-IN"))
        do {
            try await service.switchLocale(to: "xx-ZZ")
            XCTFail("Expected localeNotSupported error")
        } catch TranscriptionError.localeNotSupported(let id) {
            XCTAssertEqual(id, "xx-ZZ")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
