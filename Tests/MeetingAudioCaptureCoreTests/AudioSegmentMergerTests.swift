import AVFAudio
import Foundation
import Testing
@testable import MeetingAudioCaptureCore

@Suite
struct AudioSegmentMergerTests {
    @Test
    func mergedOutputURLReplacesPartSuffix() {
        let merger = AudioSegmentMerger()
        let segmentURL = URL(fileURLWithPath: "/tmp/session/parts/MeetingAudioCapture_1970_online-meeting_part001.m4a")

        let mergedURL = merger.mergedOutputURL(for: segmentURL)

        #expect(mergedURL.lastPathComponent == "MeetingAudioCapture_1970_online-meeting_merged.m4a")
        #expect(mergedURL.deletingLastPathComponent().path == "/tmp/session")
    }

    @Test
    func doesNotMergeSingleSegment() async throws {
        let merger = AudioSegmentMerger()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segmentURL = directory.appendingPathComponent("one_part001.wav")
        FileManager.default.createFile(atPath: segmentURL.path, contents: Data())

        let mergedURL = try await merger.merge(segments: [segmentURL], outputFormat: .wav)

        #expect(mergedURL == nil)
    }

    @Test
    func mergesWAVSegmentsAndDeletesOriginalsWhenRequested() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segments = try makeSegments(outputFormat: .wav, directory: directory, frameCount: 10_000)
        let merger = AudioSegmentMerger()

        let mergedURL = try await merger.merge(segments: segments, outputFormat: .wav, deletesSourceSegmentsOnSuccess: true)

        let outputURL = try #require(mergedURL)
        #expect(outputURL.lastPathComponent.contains("_merged.wav"))
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        for segment in segments {
            #expect(FileManager.default.fileExists(atPath: segment.path) == false)
        }

        let mergedFile = try AVAudioFile(forReading: outputURL)
        #expect(mergedFile.fileFormat.channelCount == 2)
        #expect(mergedFile.length == 10_000)
    }

    @Test
    func mergesM4ASegmentsAndDeletesOriginalsWhenRequested() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let segments = try makeSegments(outputFormat: .m4a, directory: directory, frameCount: 10_000)
        let merger = AudioSegmentMerger()

        let mergedURL = try await merger.merge(segments: segments, outputFormat: .m4a, deletesSourceSegmentsOnSuccess: true)

        let outputURL = try #require(mergedURL)
        #expect(outputURL.lastPathComponent.contains("_merged.m4a"))
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
        for segment in segments {
            #expect(FileManager.default.fileExists(atPath: segment.path) == false)
        }

        let mergedFile = try AVAudioFile(forReading: outputURL)
        #expect(mergedFile.fileFormat.channelCount == 2)
        #expect(mergedFile.length > 0)
    }

    @Test
    func mergesMP3SegmentsViaInjectedMerger() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("meeting_part001.mp3")
        let second = directory.appendingPathComponent("meeting_part002.mp3")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let merger = AudioSegmentMerger(mp3Merger: ConcatenatingMP3Merger())

        let mergedURL = try await merger.merge(segments: [first, second], outputFormat: .mp3, deletesSourceSegmentsOnSuccess: true)

        let outputURL = try #require(mergedURL)
        #expect(outputURL.lastPathComponent == "meeting_merged.mp3")
        #expect(try String(contentsOf: outputURL, encoding: .utf8) == "onetwo")
        #expect(FileManager.default.fileExists(atPath: first.path) == false)
        #expect(FileManager.default.fileExists(atPath: second.path) == false)
    }

    @Test
    func mergeKeepsPartsByDefault() async throws {
        let sessionDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let partsDirectory = sessionDirectory.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        let first = partsDirectory.appendingPathComponent("meeting_part001.mp3")
        let second = partsDirectory.appendingPathComponent("meeting_part002.mp3")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let merger = AudioSegmentMerger(mp3Merger: ConcatenatingMP3Merger())

        let mergedURL = try await merger.merge(segments: [first, second], outputFormat: .mp3)

        #expect(mergedURL?.deletingLastPathComponent() == sessionDirectory)
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test
    func repeatedMergeDoesNotOverwriteExistingResult() async throws {
        let sessionDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let partsDirectory = sessionDirectory.appendingPathComponent("parts", isDirectory: true)
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        let first = partsDirectory.appendingPathComponent("meeting_part001.mp3")
        let second = partsDirectory.appendingPathComponent("meeting_part002.mp3")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let merger = AudioSegmentMerger(mp3Merger: ConcatenatingMP3Merger())

        let firstResult = try #require(try await merger.merge(segments: [first, second], outputFormat: .mp3))
        let secondResult = try #require(try await merger.merge(segments: [first, second], outputFormat: .mp3))

        #expect(firstResult.lastPathComponent == "meeting_merged.mp3")
        #expect(secondResult.lastPathComponent == "meeting_merged_002.mp3")
        #expect(FileManager.default.fileExists(atPath: firstResult.path))
        #expect(FileManager.default.fileExists(atPath: secondResult.path))
    }

    @Test
    func keepsOriginalSegmentsWhenMergeFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("meeting_part001.mp3")
        let second = directory.appendingPathComponent("meeting_part002.mp3")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let merger = AudioSegmentMerger(mp3Merger: FailingMP3Merger())

        await #expect(throws: RecorderError.segmentMergeFailed("merge failed")) {
            try await merger.merge(
                segments: [first, second],
                outputFormat: .mp3,
                deletesSourceSegmentsOnSuccess: true
            )
        }

        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting_merged.mp3").path) == false)
    }

    private func makeSegments(outputFormat: AudioOutputFormat, directory: URL, frameCount: Int) throws -> [URL] {
        let settings = RecordingSettings(
            outputDirectory: directory,
            sampleRate: 48_000,
            bitRate: 192_000,
            outputFormat: outputFormat,
            segmentDurationSeconds: 4_096 / 48_000
        )
        let writer = SegmentedAudioFileWriter(
            settings: settings,
            mode: .onlineMeeting,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        var samples: [Float] = []
        for frame in 0..<frameCount {
            let value = Float(sin(Double(frame) / 40))
            samples.append(value)
            samples.append(value)
        }

        try writer.write(StereoPCMBuffer(sampleRate: 48_000, interleavedSamples: samples))
        try writer.close()
        #expect(writer.completedFileURLs.count > 1)
        return writer.completedFileURLs
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingAudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.standardizedFileURL
    }

    private struct ConcatenatingMP3Merger: MP3SegmentMerging {
        func merge(segments: [URL], destinationURL: URL) throws {
            var data = Data()
            for segment in segments {
                data.append(try Data(contentsOf: segment))
            }
            try data.write(to: destinationURL)
        }
    }

    private struct FailingMP3Merger: MP3SegmentMerging {
        func merge(segments: [URL], destinationURL: URL) throws {
            throw RecorderError.segmentMergeFailed("merge failed")
        }
    }
}
