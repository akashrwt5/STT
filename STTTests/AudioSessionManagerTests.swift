// AudioSessionManagerTests.swift
// STTTests

import XCTest
import AVFoundation
@testable import STT

@MainActor
final class AudioSessionManagerTests: XCTestCase {

    // MARK: - Route

    func testDefaultRouteIsBuiltInMic() {
        let manager = AudioSessionManager()
        XCTAssertEqual(manager.currentRoute, .builtInMic)
    }

    func testAudioRouteEquality() {
        let route1 = AudioRoute(name: "iPhone Mic", portType: .builtInMic, isHearingAid: false)
        let route2 = AudioRoute(name: "iPhone Mic", portType: .builtInMic, isHearingAid: false)
        XCTAssertEqual(route1, route2)
    }

    func testHearingAidRouteIsHearingAid() {
        let route = AudioRoute(name: "HearMe Pro", portType: .bluetoothHFP, isHearingAid: true)
        XCTAssertTrue(route.isHearingAid)
    }

    // MARK: - Delegate Assignment

    func testDelegateIsSetCorrectly() {
        let manager = AudioSessionManager()
        let delegate = MockAudioSessionDelegate()
        manager.delegate = delegate
        XCTAssertTrue(manager.delegate === delegate)
    }
}

// Minimal test delegate
@MainActor
private final class MockAudioSessionDelegate: AudioSessionManagerDelegate {
    func audioSessionManager(_ manager: AudioSessionManager, routeDidChangeTo route: AudioRoute) {}
    func audioSessionManagerWasInterrupted(_ manager: AudioSessionManager) {}
    func audioSessionManagerInterruptionEnded(_ manager: AudioSessionManager, shouldResume: Bool) {}
}
