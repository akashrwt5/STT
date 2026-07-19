// FMVoiceViewModel.swift
// STT — FoundationModelNLU (evaluation sample; see docs/FM_SAMPLE_PLAN.md)
//
// Mirror of PVAViewModel's wiring with the FM factory injected — a separate
// type (rather than a PVAViewModel extension) because PVAViewModel's stored
// pipeline is fixed in its designated init, and existing files stay untouched.
//
// Ownership chain — releasing this object releases the pipeline:
//   FMVoiceViewModel
//     ├── TranscriptionCoordinator      (audio / ASR — existing)
//     └── LiveTranscriptionViewModel    (existing)
//           └── NLUEngine               (existing)
//                 └── FMIntentClassifierService (FM sample)

import SwiftUI
import os.log
#if canImport(FoundationModels)

@available(iOS 26.0, *)
@Observable
@MainActor
final class FMVoiceViewModel: Identifiable {

    let id = UUID()

    /// Bind this to `LiveTranscriptionView` — the full existing conversation UI.
    let liveViewModel: LiveTranscriptionViewModel
    private let coordinator: TranscriptionCoordinator
    private var sessionStarted = false

    /// Model readiness for the header badge (FM has no Stage 3; one flag suffices).
    private(set) var engineReady = false

    // MARK: - Benchmark state (plan §8; DEBUG-only UI in FMVoiceView)

    private(set) var benchmarkRunning = false
    private(set) var benchmarkProgress: (done: Int, total: Int) = (0, 0)
    private(set) var benchmarkReport: FMBenchmarkReport?

    init() {
        let c = TranscriptionCoordinator()
        self.coordinator = c
        self.liveViewModel = LiveTranscriptionViewModel(coordinator: c, factory: FMNLUEngineFactory())
    }

    deinit {
        print("[Deinit] FMVoiceViewModel")
    }

    // MARK: - Session lifecycle (mirrors PVAViewModel.startSession)

    func startSession() {
        guard !sessionStarted else { return }
        sessionStarted = true

        // Command-style turns — endpoint on silence, same as the PVA sheet.
        liveViewModel.autoStopOnSilence = true
        liveViewModel.activate()

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.liveViewModel.awaitEngineReady()
            self.engineReady = true
        }
    }

    func teardown() {
        liveViewModel.teardown()
    }

    // MARK: - Benchmark

    func runBenchmark() {
        guard !benchmarkRunning else { return }
        benchmarkRunning = true
        benchmarkReport = nil
        benchmarkProgress = (0, 0)

        Task(priority: .userInitiated) { [weak self] in
            let report = await FMBenchmark.run { done, total in
                Task { @MainActor [weak self] in
                    self?.benchmarkProgress = (done, total)
                }
            }
            await MainActor.run { [weak self] in
                self?.benchmarkReport = report
                self?.benchmarkRunning = false
            }
        }
    }
}
#endif
