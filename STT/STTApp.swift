//
//  STTApp.swift
//  STT

import SwiftUI

@main
struct STTApp: App {

    init() {
        // Pre-warm the heaviest NLU resources OFF the main thread before any view needs
        // them. `Task.detached` is essential here: a plain `Task {}` would inherit this
        // @MainActor-isolated App.init context and run the synchronous JSON parses
        // (intent_classifier_weights.json ~ TF-IDF weights, nlu_schema.json, nlu_entities.json)
        // ON the main thread, blocking it for the duration. Under the Xcode debugger that
        // main-thread parse is amplified into a multi-second launch hang. Detached keeps it
        // on a background thread so the UI is interactive immediately.
        //
        // Now valid because IntentClassifierService/NLUSchema/EntityExtractor no longer
        // touch `Bundle.main` (which is @MainActor in Swift 6) — they use Bundle(for:).
        Task.detached(priority: .userInitiated) {
            // Touch the classifier singleton (heaviest, parsed once and cached) and build
            // a throwaway NLUEngine to warm the schema + entity JSON file reads / page cache.
            _ = IntentClassifierService.shared
            _ = NLUEngine()
        }
    }

    var body: some Scene {
        WindowGroup {
            STTTestView()
        }
    }
}
