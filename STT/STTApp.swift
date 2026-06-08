//
//  STTApp.swift
//  STT

import SwiftUI

@main
struct STTApp: App {

    init() {
        // Pre-warm the heaviest NLU resource (intent_classifier_weights.json) on a
        // background thread before any view renders. The classifier is a singleton —
        // once initialized here, every subsequent access on the main actor is instant,
        // eliminating the JSON-parse stall that blocks the first NLU call.
        Task(priority: .userInitiated) {
            _ = IntentClassifierService.shared
        }
    }

    var body: some Scene {
        WindowGroup {
            STTTestView()
        }
    }
}
