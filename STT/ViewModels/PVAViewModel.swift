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
import os.log

// MARK: - Launch instrumentation

/// Measures the "Try onDevice PVA" tap → usable-session timeline. Every milestone
/// logs as +Δms since the tap. Filter Console.app / `log stream` by subsystem
/// com.stt.module, category Latency. Logging only — no behaviour change.
@MainActor
enum PVALaunchClock {
    private static let log = Logger(subsystem: "com.stt.module", category: "Latency")
    private static var tapAt: CFAbsoluteTime?

    /// Call at the moment of the button tap.
    static func tapped() {
        tapAt = CFAbsoluteTimeGetCurrent()
        log.info("PVA LAUNCH: button tapped")
        startHangDetector()
    }

    /// Logs a milestone as +Δms since the tap. No-op if no tap was recorded.
    static func mark(_ milestone: String) {
        guard let tapAt else { return }
        let ms = (CFAbsoluteTimeGetCurrent() - tapAt) * 1000
        log.info("PVA LAUNCH: \(milestone) +\(ms, format: .fixed(precision: 0))ms")
    }

    // MARK: - Main-thread hang detection

    private static var hangTask: Task<Void, Never>?

    /// For 40s after the tap, pings the main actor from a background task every
    /// 200ms and reports any ping that takes noticeably long to be serviced —
    /// direct evidence of a main-thread block, with its duration and when it
    /// ended relative to the tap. This pinpoints stalls that produce no logs of
    /// their own (e.g. a synchronous XPC call timing out inside a framework).
    private static func startHangDetector() {
        hangTask?.cancel()
        let tapReference = CFAbsoluteTimeGetCurrent()
        hangTask = Task.detached(priority: .userInitiated) {
            while CFAbsoluteTimeGetCurrent() - tapReference < 40, !Task.isCancelled {
                let pingStart = CFAbsoluteTimeGetCurrent()
                await MainActor.run {}
                let now = CFAbsoluteTimeGetCurrent()
                let blockedMs = (now - pingStart) * 1000
                if blockedMs > 500 {
                    let endedAt = (now - tapReference) * 1000
                    log.error("PVA LAUNCH: MAIN THREAD HANG ≈\(blockedMs, format: .fixed(precision: 0))ms, ended +\(endedAt, format: .fixed(precision: 0))ms after tap")
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

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

    /// - Parameter variant: selects the NLU pipeline. The matching factory is built
    ///   here and injected into the live view model so no lower layer names a
    ///   concrete classifier type.
    init(variant: NLUVariant) {
        let c = TranscriptionCoordinator()
        self.coordinator = c
        let factory = NLUEngineFactoryProvider.make(for: variant)
        self.liveViewModel = LiveTranscriptionViewModel(coordinator: c, factory: factory)
        PVALaunchClock.mark("view model created")
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

        // PVA turns are command-style utterances — endpoint them. Without this the
        // session runs in continuous-captioning mode and every turn waits on the
        // transcriber's own lazy final commit (1.5–3s after the user stops talking)
        // before the assistant can respond. With VAD endpointing, the pipeline forces
        // finalization ~1s after end of speech instead. Set BEFORE activate(), which
        // pushes the resulting silence configuration to the coordinator.
        liveViewModel.autoStopOnSilence = true
        liveViewModel.activate()
        PVALaunchClock.mark("session activated — engine building, mic prewarming")

        // The engine (Stage 1 + 2) now builds on a background task so the sheet
        // presents without freezing — reflect real readiness instead of assuming
        // synchronous construction.
        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.liveViewModel.awaitEngineReady()
            self.stage2Status = .ready
            PVALaunchClock.mark("NLU engine ready (S2)")
            await self.liveViewModel.loadStage3()
            self.stage3Status = .ready
            PVALaunchClock.mark("semantic rescue ready (S3)")
        }
    }

    /// Gracefully stops recording and TTS. Must be called before releasing this instance
    /// (e.g., from sheet onDisappear) so in-flight audio tasks can cancel cleanly.
    func teardown() {
        liveViewModel.teardown()
    }
}
