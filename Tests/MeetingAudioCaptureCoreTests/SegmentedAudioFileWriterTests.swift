import AVFAudio
import Foundation
import Testing
@testable import MeetingAudioCaptureCore

@Suite
struct SegmentedAudioFileWriterTests {
    @Test
    func writerSplitsLongBuffersIntoMultipleM4AFiles() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingAudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let settings = RecordingSettings(
            outputDirectory: directory,
            sampleRate: 48_000,
            bitRate: 192_000,
            segmentDurationSeconds: 4_096 / 48_000
        )
        let writer = SegmentedAudioFileWriter(
            settings: settings,
            mode: .onlineMeeting,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        var samples: [Float] = []
        for frame in 0..<10_000 {
            let value = Float(sin(Double(frame) / 40))
            samples.append(value)
            samples.append(value)
        }

        try writer.write(StereoPCMBuffer(sampleRate: 48_000, interleavedSamples: samples))
        try writer.close()

        #expect(writer.completedFileURLs.count == 3)
        for fileURL in writer.completedFileURLs {
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
            #expect(fileURL.deletingLastPathComponent().lastPathComponent == "parts")
            #expect(fileURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() == directory)
        }
    }

    @Test
    func writerCreatesReadableWAVFileWhenConfigured() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingAudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let settings = RecordingSettings(
            outputDirectory: directory,
            sampleRate: 48_000,
            bitRate: 192_000,
            outputFormat: .wav,
            segmentDurationSeconds: 10
        )
        let writer = SegmentedAudioFileWriter(
            settings: settings,
            mode: .inPerson,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        let samples = Array(repeating: Float(0.25), count: 1_024 * 2)
        try writer.write(StereoPCMBuffer(sampleRate: 48_000, interleavedSamples: samples))
        try writer.close()

        #expect(writer.completedFileURLs.count == 1)
        let fileURL = try #require(writer.completedFileURLs.first)
        #expect(fileURL.pathExtension == "wav")
        #expect(fileURL.deletingLastPathComponent().lastPathComponent == "parts")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        let file = try AVAudioFile(forReading: fileURL)
        #expect(file.fileFormat.sampleRate == 48_000)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.length == 1_024)
    }

    @Test
    func writerCreatesMP3FileViaInjectedEncoderWhenConfigured() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingAudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let settings = RecordingSettings(
            outputDirectory: directory,
            sampleRate: 48_000,
            bitRate: 192_000,
            outputFormat: .mp3,
            segmentDurationSeconds: 10
        )
        let writer = SegmentedAudioFileWriter(
            settings: settings,
            mode: .onlineMeeting,
            startedAt: Date(timeIntervalSince1970: 0),
            mp3Encoder: InspectingMP3Encoder()
        )

        let samples = Array(repeating: Float(0.2), count: 512 * 2)
        try writer.write(StereoPCMBuffer(sampleRate: 48_000, interleavedSamples: samples))
        try writer.close()

        #expect(writer.completedFileURLs.count == 1)
        let fileURL = try #require(writer.completedFileURLs.first)
        #expect(fileURL.pathExtension == "mp3")
        #expect(fileURL.deletingLastPathComponent().lastPathComponent == "parts")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: fileURL.deletingPathExtension().appendingPathExtension("tmp.m4a").path) == false)
    }

    @Test
    func writerSurfacesMP3EncoderFailure() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingAudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let settings = RecordingSettings(
            outputDirectory: directory,
            sampleRate: 48_000,
            bitRate: 192_000,
            outputFormat: .mp3,
            segmentDurationSeconds: 10
        )
        let writer = SegmentedAudioFileWriter(
            settings: settings,
            mode: .onlineMeeting,
            startedAt: Date(timeIntervalSince1970: 0),
            mp3Encoder: FailingMP3Encoder()
        )

        let samples = Array(repeating: Float(0.2), count: 512 * 2)
        try writer.write(StereoPCMBuffer(sampleRate: 48_000, interleavedSamples: samples))

        #expect(throws: RecorderError.mp3EncoderUnavailable) {
            try writer.close()
        }
        #expect(writer.completedFileURLs.isEmpty)
        let sessionDirectory = try #require(writer.sessionDirectoryURL)
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: sessionDirectory.appendingPathComponent("parts", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        #expect(recoveryFiles.count == 1)
        #expect(recoveryFiles[0].lastPathComponent.hasSuffix("tmp.m4a"))
    }

    @Test
    func sameRecordingNameCreatesUniqueSessionDirectories() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("MeetingAudioCaptureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = RecordingSettings(outputDirectory: directory)
        let startedAt = Date(timeIntervalSince1970: 0)

        let first = SegmentedAudioFileWriter(settings: settings, mode: .inPerson, startedAt: startedAt)
        let second = SegmentedAudioFileWriter(settings: settings, mode: .inPerson, startedAt: startedAt)
        let buffer = StereoPCMBuffer(sampleRate: 48_000, interleavedSamples: [0.1, 0.1])
        try first.write(buffer)
        try first.close()
        try second.write(buffer)
        try second.close()

        let firstDirectory = try #require(first.sessionDirectoryURL)
        let secondDirectory = try #require(second.sessionDirectoryURL)
        #expect(firstDirectory != secondDirectory)
        #expect(secondDirectory.lastPathComponent.hasSuffix("_002"))
    }

    private struct InspectingMP3Encoder: MP3Encoding {
        func encodeM4A(sourceURL: URL, destinationURL: URL) throws {
            #expect(sourceURL.pathExtension == "m4a")
            #expect(sourceURL.lastPathComponent.hasSuffix("tmp.m4a"))
            let sourceFile = try AVAudioFile(forReading: sourceURL)
            #expect(sourceFile.fileFormat.channelCount == 2)
            try Data(contentsOf: sourceURL).write(to: destinationURL)
        }
    }

    private struct FailingMP3Encoder: MP3Encoding {
        func encodeM4A(sourceURL: URL, destinationURL: URL) throws {
            throw RecorderError.mp3EncoderUnavailable
        }
    }

}
