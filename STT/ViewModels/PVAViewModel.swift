// PVAViewModel.swift
// STT
//
// Self-contained view model for an onDevice PVA session sheet.
// Creates its own TranscriptionCoordinator + LiveTranscriptionViewModel pair,
// auto-loads Stage 3 in the background, and tears everything down cleanly on dismiss.
//
// Ownership chain — releasing this object releases the entire pipeline:
//   PVAViewModel
//     ├── TranscriptionCoordinator   (audio / ASR)
//     └── LiveTranscriptionViewModel
//           └── NLUEngine
//                 └── IntentClassifierService (S1 keyword + S2 CoreML + S3 MiniLM)
//                       ├── SemanticEmbedder   (MiniLM-L6-v2 weights)
//                       └── SemanticClassifier (linear head)

import SwiftUI

// MARK: - Stage readiness

/// Loading state of a single NLU pipeline stage.
enum StageReadiness: Equatable {
    /// Not yet initialized or still loading.
    case loading
    /// Fully loaded and ready to classify.
    case ready
    /// Initialization failed (missing bundle artifact or CoreML error).
    case failed
}

// MARK: - View model

@Observable
@MainActor
final class PVAViewModel: Identifiable {

    let id = UUID()

    // MARK: - Stage readiness (drives the pipeline indicator in PVASheetView)

    /// Stage 1 — keyword rules. Synchronous; always ready immediately.
    private(set) var stage1Status: StageReadiness = .ready
    /// Stage 2 — TF-IDF + CoreML LogReg. Loads synchronously in IC init; ready after activate().
    private(set) var stage2Status: StageReadiness = .loading
    /// Stage 3 — MiniLM-L6-v2 + SemanticHead. Loads on a background task after session starts.
    private(set) var stage3Status: StageReadiness = .loading

    // MARK: - Session components

    /// Bind this to `LiveTranscriptionView`.
    let liveViewModel: LiveTranscriptionViewModel
    private let coordinator: TranscriptionCoordinator
    private var sessionStarted = false

    // MARK: - Init / deinit

    init() {
        let c = TranscriptionCoordinator()
        self.coordinator = c
        self.liveViewModel = LiveTranscriptionViewModel(coordinator: c)
    }

    deinit {
        print("[Deinit] PVAViewModel")
    }

    // MARK: - Session lifecycle

    /// Activates the session. Idempotent — safe to call from multiple onAppear sites.
    ///
    /// Calls `liveViewModel.activate()` which wires the delegate, creates
    /// IntentClassifierService + NLUEngine synchronously, and triggers coordinator
    /// prewarm. Stage 1 and Stage 2 are ready on return. Stage 3 loads asynchronously.
    func startSession() {
        guard !sessionStarted else { return }
        sessionStarted = true

        liveViewModel.activate()
        stage2Status = .ready  // IntentClassifierService.init() loaded CoreML synchronously

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.liveViewModel.loadStage3()
            self.stage3Status = .ready
        }
    }

    /// Gracefully stops recording and TTS. Must be called before releasing this instance
    /// (e.g., from sheet onDisappear) so in-flight audio tasks can cancel cleanly.
    func teardown() {
        liveViewModel.teardown()
    }
}
