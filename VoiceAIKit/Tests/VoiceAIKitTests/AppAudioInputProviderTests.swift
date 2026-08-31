// AppAudioInputProviderTests.swift
// VoiceAIKitTests
//
// The host-owned audio path: raw Int16-mono `Data` in, `AVAudioPCMBuffer`s out.
// Covers the buffer format/length, frame-alignment handling, and the "drop between
// turns" rule that keeps trailing audio from bleeding into the next turn.

import XCTest
import AVFoundation
@testable import VoiceAIKit

final class AppAudioInputProviderTests: XCTestCase {

    private let sampleRate: Double = 16_000

    /// 4 bytes = two Int16 mono frames.
    private let twoFrames = Data([0x01, 0x02, 0x03, 0x04])

    func testDeclaredFormatIsInt16MonoAtSampleRate() async throws {
        let provider = AppAudioInputProvider(sampleRate: sampleRate)
        let format = try await provider.audioFormat
        XCTAssertEqual(format.sampleRate, sampleRate, accuracy: 0.0001)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }

    func testEnqueueYieldsBufferWithCorrectFrameLength() async throws {
        let provider = AppAudioInputProvider(sampleRate: sampleRate)
        let stream = provider.start()
        provider.enqueue(twoFrames)

        var iterator = stream.makeAsyncIterator()
        let buffer = await iterator.next()
        XCTAssertNotNil(buffer)
        XCTAssertEqual(buffer?.frameLength, 2)          // 4 bytes / 2 bytes-per-frame
        XCTAssertEqual(buffer?.format.sampleRate, sampleRate)
    }

    func testMisalignedByteCountIsTruncatedToWholeFrames() async throws {
        let provider = AppAudioInputProvider(sampleRate: sampleRate)
        let stream = provider.start()
        // 5 bytes = 2 whole Int16 frames + 1 stray byte; the stray byte is dropped.
        provider.enqueue(Data([0x01, 0x02, 0x03, 0x04, 0x05]))

        var iterator = stream.makeAsyncIterator()
        let buffer = await iterator.next()
        XCTAssertEqual(buffer?.frameLength, 2)
    }

    func testAudioPushedAfterStopIsDropped() async throws {
        let provider = AppAudioInputProvider(sampleRate: sampleRate)
        let stream = provider.start()
        provider.stop()
        // Pushed after the turn ended — must not be delivered.
        provider.enqueue(twoFrames)

        var iterator = stream.makeAsyncIterator()
        let buffer = await iterator.next()
        XCTAssertNil(buffer, "stream should be finished after stop(); trailing audio is dropped")
    }

    func testEmptyDataIsIgnored() async throws {
        let provider = AppAudioInputProvider(sampleRate: sampleRate)
        let stream = provider.start()
        provider.enqueue(Data())       // no-op
        provider.enqueue(twoFrames)    // the real one

        var iterator = stream.makeAsyncIterator()
        let buffer = await iterator.next()
        XCTAssertEqual(buffer?.frameLength, 2)   // first real buffer, empty was skipped
    }
}
