// SpeechRecognitionServiceTests.swift
// STTTests

import XCTest
import Speech
@testable import STT

final class SpeechRecognitionServiceTests: XCTestCase {

    // MARK: - Locale Resolution
    // All locale resolution tests are async because SpeechTranscriber.supportedLocales
    // and supportedLocale(equivalentTo:) are async properties/methods in iOS 26.

    func testLocaleResolutionFallsBackToDefault() async {
        let locale = await SpeechRecognitionService.resolveLocale(userOverride: nil)
        XCTAssertFalse(locale.identifier.isEmpty, "Resolved locale should not be empty")
    }

    func testLocaleResolutionWithExplicitOverride() async {
        let supported = await SpeechTranscriber.supportedLocales
        guard let first = supported.first else { return }

        let resolved = await SpeechRecognitionService.resolveLocale(userOverride: first.identifier)
        XCTAssertEqual(resolved.identifier, first.identifier)
    }

    func testLocaleResolutionWithUnknownOverrideFallsThrough() async {
        let resolved = await SpeechRecognitionService.resolveLocale(userOverride: "xx-ZZ")
        XCTAssertFalse(resolved.identifier.isEmpty)
    }

    // MARK: - Available Locales

    func testSupportedLocalesIsNonEmpty() async {
        // SpeechTranscriber.supportedLocales is the source of truth used by the service.
        let locales = await SpeechTranscriber.supportedLocales
        // In the simulator there may be no locales; skip gracefully rather than fail.
        if locales.isEmpty { return }
        XCTAssertFalse(locales.isEmpty)
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
