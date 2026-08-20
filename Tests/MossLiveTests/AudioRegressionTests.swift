import AVFoundation
@testable import MossLive
import XCTest

final class AudioRegressionTests: XCTestCase {
    /// Fixed 20 ms recordings, not generated at test time. The first is quiet
    /// speech-like audio with a deterministic room-noise bed; the second is the
    /// same tone overdriven into clipping.
    private static let quietFixture = """
    8/9eAo8DkQV+B10Jkwp9C7ALugsjC/kK/gnMCPsHCwYTBNQCfAAn/lL8efrR+Nr3dfYh9a70W/Tt8wD16/UM9xb4Pvk5
    +y/9m/9mAZQDFwVbBlYIQAq5CoQLXgtMC9AKhQpGCdIHewZPBZkCrwBs/6H9s/rk+UT4iPYo9Uj05vPG9BH0xPQ99sv3
    rvjY+kH8v/7TALUCFQRiBmsIewloCsUKYQs+CwkL1QpgCqoIGAcqBk8D2wHT/2T+0PsD+s/4EPdG9VL1k/Rx9KT0qvRA
    9Y728Pc/+iP8a/2w/2sCFwTKBS0HmwjkCQMLlwtvC10LFAvJCjsJLgjDBskEUgJ8AA7+evw5+6j4A/j19Rz1TfSg9Av0
    TfTb9Xv2K/h3+bv7ofyk/hcB1wJvBU4HwQiCCR8LrgtVCzAMcwvnCsIJdgiCBqgFyQNrAc3/Fv3S+kb5L/jf9lv1RfR1
    9Fn0b/SE9dH1m/dS+HT6UfwY/nsABQKIBOEF0QcbCR0KjgoIDFAL4wsjC6EK4gguBxMGzQOnAUUAgv2J+735pfjl9p71
    m/QA9aX0ePSL9E322PaX+Fj65vuz/eT/EALIA9sFRwfPCKcJdwoJC0sLGQupCoAK1AgdCOkGrwQXA/AARv+z/In63/h/
    9/H1KfXd9Bv0zvPq9KH13fZ+93L5VfuL/PX+CgF3AvEEogY0CPIInQqyCsML1guLC3AKWwoPCRAHywSoA8IB+v4l/W/7
    bvm490P2q/WZ9Fb0FvSQ9Lr0FPYN9y/43vkP/Jn9wP8mAvgDvwWeB3wIYAqWCqQLyQs2CykLBwqUCfgHVAYIBK4Cw/97
    /t37n/qQ+M/2rPXV9I/09fNC9A==
    """

    private static let clippedFixture = """
    AAA5Hos7GFcMcP9//3//f/9//3//f/9//3//fz902Fu2QKUjhQU7567Jv61DlACAAIAAgACAAIAAgACAAIAAgKuHfp8wuvfW9vRKEwsx
    VU1SZzx+/3//f/9//3//f/9//3//f0x8E2XYSmIuixA18knUqrcynayFAIAAgACAAIAAgACAAIAAgACAdZYysFDM+OlICFgmRUMwXk52/
    3//f/9//3//f/9//3//f/9/6G2vVPA4gBs9/RDf3sGFpteNAIAAgACAAIAAgACAAIAAgACA142Fpt7BEN89/YAb8DivVOht/3//f/9//
    3//f/9//3//f/9/TnYwXkVDWCZICPjpUMwysHWWAIAAgACAAIAAgACAAIAAgACArIUynaq3SdQ18osQYi7YShNlTHz/f/9//3//f/9//
    3//f/9/PH5SZ1VNCzFKE/b099Ywun6fq4cAgACAAIAAgACAAIAAgACAAIBDlL+trsk754UFpSO2QNhbP3T/f/9//3//f/9//3//f/9/
    /38McBhXizs5HgAAx+F1xOio9I8AgACAAIAAgACAAIAAgACAAIDBiyikSr9b3Hv6xRhSNkFSvWv/f/9//3//f/9//3//f/9//39VeI
    Jg0EUJKQoLtuz1zquyrpjEgQCAAIAAgACAAIAAgACAAIC0g+2aKLWe0XXvyw23K1ZIzmJUev9//3//f/9//3//f/9//3//f4tpzk+w
    MwgWuPeo2bu80KGyiQCAAIAAgACAAIAAgACAAIAAgBiSUasQx4DkwwLwICI+e1kpcv9//3//f/9//3//f/9//3//fylye1kiPvAgww
    KA5BDHUasYkgCAAIAAgACAAIAAgA==
    """

    func testFixedQuietRecordingKeepsExpectedLevel() throws {
        var analyzer = AudioSignalAnalyzer()
        let measurement = try analyzer.consume(samples(Self.quietFixture))

        XCTAssertEqual(measurement.rmsDBFS, -23.8, accuracy: 1.0)
        XCTAssertLessThan(measurement.clippedSamplePercent, 0.01)
        XCTAssertGreaterThan(measurement.level, 0.5)
    }

    func testFixedClippedRecordingIsDetected() throws {
        var analyzer = AudioSignalAnalyzer()
        let measurement = try analyzer.consume(samples(Self.clippedFixture))

        XCTAssertGreaterThan(measurement.clippedSamplePercent, 35)
        XCTAssertGreaterThan(measurement.peakDBFS, -0.2)
    }

    func testFixedRecordingProducesExactlyOneOpusFrame() throws {
        let encoder = try OpusStreamEncoder(bitrate: 24000)
        let packets = try encoder.feed(samples(Self.quietFixture), captureTsMs: 123)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].seq, 0)
        XCTAssertEqual(packets[0].captureTsMs, 123)
        XCTAssertFalse(packets[0].payload.isEmpty)
    }

    func testTapBufferDeepCopyOwnsItsSamples() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: 16000,
                channels: 1,
                interleaved: true
            )
        )
        let original = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        original.frameLength = 4
        let source = try XCTUnwrap(original.int16ChannelData?[0])
        source[0] = 101
        source[1] = 202
        source[2] = 303
        source[3] = 404

        let copy = try XCTUnwrap(original.deepCopy())
        source[0] = -999

        XCTAssertEqual(copy.int16ChannelData?[0][0], 101)
        XCTAssertEqual(copy.int16ChannelData?[0][3], 404)
    }

    func testDiskSpoolPersistsOrderingWithoutHoldingFrameArray() throws {
        let root = temporaryDirectory().appendingPathComponent("spool")
        let spool = DiskAudioSpool(root: root)
        XCTAssertEqual(try spool.begin(id: UUID()), 0)
        let first = Data([1, 2, 3])
        let second = Data([4, 5])
        try spool.append(first)
        try spool.append(second)

        XCTAssertEqual(try spool.peek(), first)
        spool.acknowledge(first)
        XCTAssertEqual(try spool.peek(), second)
        XCTAssertEqual(spool.status().pendingFrames, 1)
        spool.finish()

        let relaunched = DiskAudioSpool(root: root)
        XCTAssertEqual(try relaunched.begin(id: UUID()), 1)
    }

    func testManifestCheckpointsFramesAndFinalState() throws {
        let root = temporaryDirectory().appendingPathComponent("recordings")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            )
        )
        let writer = try LocalRecordingWriter(root: root, format: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        for _ in 0 ..< 10 {
            try writer.write(buffer)
        }
        writer.setServerSessionId("lesson-48khz")

        let manifestURL = writer.finish()
        let manifest = try LocalRecordingStorage.load(from: manifestURL)
        XCTAssertEqual(manifest.state, .finalizing)
        XCTAssertEqual(manifest.serverSessionId, "lesson-48khz")
        XCTAssertEqual(manifest.framesWritten, 4800)
        XCTAssertEqual(manifest.durationSeconds, 0.1, accuracy: 0.001)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: manifestURL.deletingLastPathComponent()
                    .appendingPathComponent(LocalRecordingStorage.pcmName).path
            )
        )

        let matched = LocalRecordingStorage.matchingRecording(
            root: root,
            sessionId: "lesson-48khz",
            lessonStartedAt: manifest.startedAt
        )
        XCTAssertEqual(matched?.id, manifest.id)
        XCTAssertEqual(matched?.manifestURL, manifestURL)

        LocalRecordingStorage.setNeedsServerRecovery(true, manifestURL: manifestURL)
        XCTAssertTrue(try LocalRecordingStorage.load(from: manifestURL).needsServerRecovery == true)
        XCTAssertTrue(LocalRecordingStorage.summaries(root: root)[0].needsServerRecovery)

        let splitLessonMatch = LocalRecordingStorage.matchingRecording(
            root: root,
            sessionId: "server-created-child-id",
            lessonStartedAt: manifest.startedAt.addingTimeInterval(0.05)
        )
        XCTAssertEqual(splitLessonMatch?.id, manifest.id)
    }

    func testInterruptedPCMRecordingRecoversAsM4A() async throws {
        let root = temporaryDirectory().appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48000,
                channels: 1,
                interleaved: false
            )
        )
        let startedAt = Date()
        var writer: LocalRecordingWriter? = try LocalRecordingWriter(
            root: root,
            format: format,
            now: startedAt
        )
        let manifestURL = try XCTUnwrap(writer?.manifestURL)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        try writer?.write(buffer, now: startedAt.addingTimeInterval(2))
        writer?.setServerSessionId("interrupted-session")
        writer = nil // simulate process termination without finish()

        let recovered = await LocalRecordingRecovery.recoverPending(root: root)
        let manifest = try LocalRecordingStorage.load(from: manifestURL)

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(manifest.state, .recovered)
        XCTAssertTrue(manifest.needsServerRecovery == true)
        XCTAssertTrue(recovered[0].needsServerRecovery)
        XCTAssertEqual(manifest.durationSeconds, 0.1, accuracy: 0.001)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: manifestURL.deletingLastPathComponent()
                    .appendingPathComponent(LocalRecordingStorage.m4aName).path
            )
        )
    }

    private func samples(_ base64: String) throws -> [Int16] {
        let compact = base64.filter { !$0.isWhitespace }
        let data = try XCTUnwrap(Data(base64Encoded: compact))
        XCTAssertEqual(data.count % 2, 0)
        return stride(from: 0, to: data.count, by: 2).map { index in
            let bits = UInt16(data[index]) | UInt16(data[index + 1]) << 8
            return Int16(bitPattern: bits)
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoAudioTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
