// AudioSessionManager.swift
// STT
//
// Single responsibility: AVAudioSession lifecycle, route management, hearing aid detection.

import AVFoundation
import os.log

/// Describes the currently active audio input source.
public struct AudioRoute: Sendable, Equatable {
    public let name: String
    public let portType: AVAudioSession.Port
    public let isHearingAid: Bool

    public static let builtInMic = AudioRoute(
        name: "iPhone Mic",
        portType: .builtInMic,
        isHearingAid: false
    )
}

/// Receives notifications about audio session lifecycle events.
@MainActor
public protocol AudioSessionManagerDelegate: AnyObject {
    func audioSessionManager(_ manager: AudioSessionManager, routeDidChangeTo route: AudioRoute)
    func audioSessionManagerWasInterrupted(_ manager: AudioSessionManager)
    func audioSessionManagerInterruptionEnded(_ manager: AudioSessionManager, shouldResume: Bool)
}

/// Owns AVAudioSession configuration, audio route management, and hearing aid detection.
///
/// This class does not own any audio capture — that is `AudioCaptureService`'s concern.
@MainActor
public final class AudioSessionManager {

    // MARK: - Public

    public private(set) var currentRoute: AudioRoute = .builtInMic
    public weak var delegate: AudioSessionManagerDelegate?

    // MARK: - Private

    private let session: AVAudioSession
    private let logger = Logger(subsystem: "com.stt.module", category: "AudioSessionManager")

    // MARK: - Init

    /// - Parameter session: Injectable for testability. Defaults to `AVAudioSession.sharedInstance()`.
    public init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    // MARK: - Setup

    /// Configures the audio session for high-quality recording.
    ///
    /// Sets category to `.record` and mode to `.measurement` so the system applies
    /// minimal signal processing, which yields cleaner input for the speech analyzer.
    ///
    /// - Throws: `TranscriptionError.audioSessionSetupFailed` if configuration fails.
    ///
    /// `async` so the blocking `AVAudioSession` calls (`setActive`, `setCategory`) run
    /// off the main thread — activating the audio session spins up the audio hardware
    /// and can block for hundreds of milliseconds, freezing the UI if done on the main
    /// actor. `AVAudioSession` is a thread-safe singleton, so this is safe.
    public func configure() async throws {
        do {
            // AVAudioSession is a thread-safe singleton; safe to use off the main actor.
            nonisolated(unsafe) let session = self.session
            try await Task.detached(priority: .userInitiated) {
                // .allowBluetooth enables Bluetooth HFP input (hearing aids, headsets).
                // .allowBluetoothA2DP is intentionally excluded — it is an output-only
                // protocol and is incompatible with the .record category, causing
                // "the operation could not be completed" at runtime.
                try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
                try session.setActive(true)
            }.value

            // Route inspection + observer registration is lightweight; keep on main actor.
            preferHearingAidInputIfAvailable()
            // Remove before re-adding so repeated configure() calls don't stack observers.
            NotificationCenter.default.removeObserver(self)
            registerForNotifications()
            updateCurrentRoute()
            logger.info("Audio session configured. Route: \(self.currentRoute.name)")
        } catch {
            logger.error("Audio session setup failed: \(error)")
            throw TranscriptionError.audioSessionSetupFailed(error)
        }
    }

    /// Deactivates the audio session and removes notification observers.
    public func tearDown() {
        NotificationCenter.default.removeObserver(self)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
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
            try? session.setActive(true)
            delegate?.audioSessionManagerInterruptionEnded(self, shouldResume: shouldResume)

        @unknown default:
            break
        }
    }
}
