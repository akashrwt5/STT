// AudioSessionManager.swift
// STT
//
// Single responsibility: AVAudioSession lifecycle, route management, hearing aid detection.

import AVFoundation
import os.log

/// Describes the currently active audio input source.
struct AudioRoute: Sendable, Equatable {
    let name: String
    let portType: AVAudioSession.Port
    let isHearingAid: Bool

    static let builtInMic = AudioRoute(
        name: "iPhone Mic",
        portType: .builtInMic,
        isHearingAid: false
    )
}

/// Receives notifications about audio session lifecycle events.
@MainActor
protocol AudioSessionManagerDelegate: AnyObject {
    func audioSessionManager(_ manager: AudioSessionManager, routeDidChangeTo route: AudioRoute)
    func audioSessionManagerWasInterrupted(_ manager: AudioSessionManager)
    func audioSessionManagerInterruptionEnded(_ manager: AudioSessionManager, shouldResume: Bool)
}

/// Owns AVAudioSession configuration, audio route management, and hearing aid detection.
///
/// This class does not own any audio capture — that is `AudioCaptureService`'s concern.
@MainActor
final class AudioSessionManager {

    // MARK: - Public

    private(set) var currentRoute: AudioRoute = .builtInMic
    weak var delegate: AudioSessionManagerDelegate?

    // MARK: - Private

    private let session: AVAudioSession
    /// True once the session is configured and active. `configure()` early-returns
    /// while this holds: re-running setCategory/setActive on the live session cost
    /// ~550ms on every conversation turn's mic restart — time during which the
    /// user's first words after the prompt were not being captured. Cleared by
    /// `tearDown()` and by an interruption (both invalidate the active state).
    private var isConfigured = false
    private let logger = Logger(subsystem: "com.voiceaikit", category: "AudioSessionManager")

    // MARK: - Init

    /// - Parameter session: Injectable for testability. Defaults to `AVAudioSession.sharedInstance()`.
    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    // MARK: - Setup

    /// Configures the audio session for combined recording + playback.
    ///
    /// Uses a single `.playAndRecord` / `.spokenAudio` configuration shared by the
    /// mic and the TTS voice. This is deliberate: previously the mic used
    /// `.record`/`.measurement` and TTS flipped the session to `.playAndRecord` on
    /// every prompt. That per-turn category churn left the session contested and made
    /// `AVSpeechSynthesizer` silently drop the second prompt (it fired `didFinish`
    /// without `didStart`, so no audio played). Keeping one category eliminates the
    /// churn — `ConversationSpeaker` only needs to re-activate, never re-categorise.
    ///
    /// Trade-off: `.playAndRecord` cannot use `.measurement` mode, so STT input gets
    /// the default signal processing rather than the minimal-processing path.
    /// `.spokenAudio` is appropriate for speech and is the same configuration TTS
    /// already used successfully.
    ///
    /// - Throws: `TranscriptionError.audioSessionSetupFailed` if configuration fails.
    ///
    /// `async` so the blocking `AVAudioSession` calls (`setActive`, `setCategory`) run
    /// off the main thread — activating the audio session spins up the audio hardware
    /// and can block for hundreds of milliseconds, freezing the UI if done on the main
    /// actor. `AVAudioSession` is a thread-safe singleton, so this is safe.
    func configure() async throws {
        // Already configured and never deactivated (the conversation flow keeps the
        // session up across recognizer↔TTS handoffs) — just refresh route state.
        if isConfigured {
            updateCurrentRoute()
            return
        }
        do {
            // AVAudioSession is a thread-safe singleton; safe to use off the main actor.
            nonisolated(unsafe) let session = self.session
            try await Task.detached(priority: .userInitiated) {
                // .defaultToSpeaker routes TTS to the loudspeaker (not the earpiece).
                // .duckOthers lowers other apps' audio while we speak.
                // .allowBluetooth enables Bluetooth HFP input (hearing aids, headsets).
                // .allowBluetoothA2DP is intentionally excluded — it is output-only and
                // incompatible with a record-capable category.
                try session.setCategory(.playAndRecord, mode: .spokenAudio,
                                        options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
                try session.setActive(true)
            }.value

            // Route inspection + observer registration is lightweight; keep on main actor.
            preferHearingAidInputIfAvailable()
            // Remove before re-adding so repeated configure() calls don't stack observers.
            NotificationCenter.default.removeObserver(self)
            registerForNotifications()
            updateCurrentRoute()
            isConfigured = true
            logger.info("Audio session configured. Route: \(self.currentRoute.name)")
        } catch {
            logger.error("Audio session setup failed: \(error)")
            throw TranscriptionError.audioSessionSetupFailed(error)
        }
    }

    /// Releases the audio session if this manager is dropped without `tearDown()`.
    ///
    /// `AVAudioSession` is a PROCESS-WIDE SINGLETON. It is never deallocated, so an
    /// activation that is never balanced outlives this object, the coordinator that
    /// owned it and the `VoiceIntentSession` above that — other apps stay ducked and
    /// the microphone indicator can stay lit for the rest of the app's life. Nothing
    /// in ARC cleans that up, because there is no object to clean up.
    ///
    /// A host reaching this is not misusing the SDK in an exotic way; it is the normal
    /// shape of a dismissed screen or a released view model. `stop()` is still the
    /// right thing to call — this is the floor under it, not a replacement.
    ///
    /// Safe from a nonisolated `deinit` for exactly the reason `configure()` already
    /// depends on: `AVAudioSession` is thread-safe, which is why `configure()` calls
    /// `setActive(true)` from inside `Task.detached` in the first place.
    ///
    /// Guarded on `isConfigured` so a manager that never activated the session cannot
    /// deactivate one that somebody else did. That guard also covers app-provided audio:
    /// `configure()` only runs when the coordinator owns the session, so in
    /// `.appProvided` mode `isConfigured` is never true and this cannot deactivate a
    /// session the HOST owns.
    ///
    /// Note there is no `removeObserver(self)` here. The two registrations in
    /// `registerForNotifications()` use the selector-based
    /// `addObserver(_:selector:name:object:)`, which NotificationCenter removes
    /// automatically when the observer deallocates (iOS 9+). The call in `tearDown()` is
    /// NOT redundant in the same way — that one runs while this object is still alive, to
    /// stop delivery before a reconfigure.
    deinit {
        guard isConfigured else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Deactivates the audio session and removes notification observers.
    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isConfigured = false
        logger.info("Audio session torn down.")
    }

    // MARK: - Route Management

    /// Inspects available inputs and promotes a hearing aid or Bluetooth HFP device if found.
    private func preferHearingAidInputIfAvailable() {
        guard let inputs = session.availableInputs else { return }

        let preferredPortTypes: [AVAudioSession.Port] = [.bluetoothLE, .bluetoothHFP, .bluetoothA2DP]
        let hearingAidPort = inputs.first { port in
            preferredPortTypes.contains(port.portType)
        }

        if let port = hearingAidPort {
            do {
                try session.setPreferredInput(port)
                logger.info("Preferred input set to hearing aid: \(port.portName)")
            } catch {
                logger.warning("Could not set preferred input to hearing aid: \(error)")
            }
        }
    }

    private func updateCurrentRoute() {
        guard let input = session.currentRoute.inputs.first else {
            currentRoute = .builtInMic
            return
        }

        let hearingAidPorts: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothLE, .bluetoothA2DP]
        currentRoute = AudioRoute(
            name: input.portName,
            portType: input.portType,
            isHearingAid: hearingAidPorts.contains(input.portType)
        )
    }

    // MARK: - Notifications

    private func registerForNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        logger.info("Audio route changed: \(String(describing: reason))")
        preferHearingAidInputIfAvailable()
        updateCurrentRoute()
        delegate?.audioSessionManager(self, routeDidChangeTo: currentRoute)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            logger.info("Audio interruption began.")
            // The system deactivated us — the next configure() must run fully.
            isConfigured = false
            delegate?.audioSessionManagerWasInterrupted(self)

        case .ended:
            let shouldResume: Bool
            if let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            } else {
                shouldResume = false
            }
            logger.info("Audio interruption ended. Should resume: \(shouldResume)")
            // Only reactivate when we actually intend to resume — blindly calling
            // setActive(true) grabbed the audio hardware even when idle. Log failures
            // instead of discarding them; the coordinator surfaces its own errors when
            // the restart attempt runs.
            if shouldResume {
                do { try session.setActive(true) }
                catch { logger.error("Failed to reactivate session after interruption: \(error)") }
            }
            delegate?.audioSessionManagerInterruptionEnded(self, shouldResume: shouldResume)

        @unknown default:
            break
        }
    }
}
