import AVFAudio
import Foundation
import Testing
@testable import MeetingAudioCaptureCore

@Suite
struct SavedAudioSegmentMergerTests {
    @Test
    func detectsPartsDirectoryAndSortsSegmentsByNumber() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let parts = session.appendingPathComponent("parts", isDirectory: true)
        try Data().write(to: parts.appendingPathComponent("meeting_part003.m4a"))
        try Data().write(to: parts.appendingPathComponent("meeting_part001.m4a"))

        let plan = try SavedAudioSegmentMerger().makePlan(selectedDirectory: session)

        #expect(plan.segments.map(\.lastPathComponent) == ["meeting_part001.m4a", "meeting_part003.m4a"])
        #expect(plan.missingSegmentIndices == [2])
        #expect(plan.outputFormat == .m4a)
        #expect(plan.sessionDirectory == session)
    }

    @Test
    func acceptsPartsDirectoryDirectly() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let parts = session.appendingPathComponent("parts", isDirectory: true)
        try Data().write(to: parts.appendingPathComponent("meeting_part001.mp3"))
        try Data().write(to: parts.appendingPathComponent("meeting_part002.mp3"))

        let plan = try SavedAudioSegmentMerger().makePlan(selectedDirectory: parts)

        #expect(plan.sessionDirectory == session)
        #expect(plan.outputFormat == .mp3)
    }

    @Test
    func rejectsMixedFormats() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let parts = session.appendingPathComponent("parts", isDirectory: true)
        try Data().write(to: parts.appendingPathComponent("meeting_part001.m4a"))
        try Data().write(to: parts.appendingPathComponent("meeting_part002.mp3"))

        #expect(throws: SavedAudioSegmentMergeError.mixedOutputFormats) {
            try SavedAudioSegmentMerger().makePlan(selectedDirectory: session)
        }
    }

    @Test
    func rejectsSingleSegment() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let parts = session.appendingPathComponent("parts", isDirectory: true)
        try Data().write(to: parts.appendingPathComponent("meeting_part001.m4a"))

        #expect(throws: SavedAudioSegmentMergeError.onlyOneSegment) {
            try SavedAudioSegmentMerger().makePlan(selectedDirectory: session)
        }
    }

    @Test
    func reportsExistingMergedFiles() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let parts = session.appendingPathComponent("parts", isDirectory: true)
        try Data().write(to: parts.appendingPathComponent("meeting_part001.mp3"))
        try Data().write(to: parts.appendingPathComponent("meeting_part002.mp3"))
        try Data().write(to: session.appendingPathComponent("meeting_merged.mp3"))

        let plan = try SavedAudioSegmentMerger().makePlan(selectedDirectory: session)

        #expect(plan.existingMergedFiles.map(\.lastPathComponent) == ["meeting_merged.mp3"])
    }

    @Test
    func rejectsMismatchedWAVFormatsBeforeMerge() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let parts = session.appendingPathComponent("parts", isDirectory: true)
        try writeWAV(to: parts.appendingPathComponent("meeting_part001.wav"), sampleRate: 48_000, channels: 2)
        try writeWAV(to: parts.appendingPathComponent("meeting_part002.wav"), sampleRate: 44_100, channels: 2)

        #expect(throws: SavedAudioSegmentMergeError.inconsistentWAVFormat("meeting_part002.wav")) {
            try SavedAudioSegmentMerger().makePlan(selectedDirectory: session)
        }
    }

    @Test
    func mergesValidatedWAVPartsAtSessionRootAndKeepsSources() async throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        let parts = session.appendingPathComponent("parts", isDirectory: true)
        let first = parts.appendingPathComponent("meeting_part001.wav")
        let second = parts.appendingPathComponent("meeting_part002.wav")
        try writeWAV(to: first, sampleRate: 48_000, channels: 2)
        try writeWAV(to: second, sampleRate: 48_000, channels: 2)
        let merger = SavedAudioSegmentMerger()
        let plan = try merger.makePlan(selectedDirectory: session)

        let output = try await merger.merge(plan)

        #expect(
            output.deletingLastPathComponent().resolvingSymlinksInPath()
                == session.resolvingSymlinksInPath()
        )
        #expect(output.lastPathComponent == "meeting_merged.wav")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    private func makeSession() throws -> URL {
        let session = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingAudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: session.appendingPathComponent("parts", isDirectory: true),
            withIntermediateDirectories: true
        )
        return session
    }

    private func writeWAV(to url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        file.close()
    }
}
