import AVFAudio
import AudioToolbox
import Foundation

extension AudioOutputFormat {
    var writesViaIntermediateM4A: Bool {
        self == .mp3
    }

    func avAudioFileSettings(sampleRate: Double, bitRate: Int) -> [String: Any] {
        switch self {
        case .m4a:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: bitRate
            ]
        case .wav:
            return [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false
            ]
        case .mp3:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: bitRate
            ]
        }
    }
}

extension StereoPCMBuffer {
    func makeAVAudioPCMBuffer() throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw RecorderError.invalidBuffer("AVAudioFormatを作成できませんでした。")
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw RecorderError.invalidBuffer("AVAudioPCMBufferを作成できませんでした。")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channelData = buffer.floatChannelData else {
            throw RecorderError.invalidBuffer("PCMバッファのチャンネルデータにアクセスできません。")
        }

        for frame in 0..<frameCount {
            channelData[0][frame] = interleavedSamples[frame * 2]
            channelData[1][frame] = interleavedSamples[frame * 2 + 1]
        }

        return buffer
    }
}

public final class SegmentedAudioFileWriter {
    public private(set) var completedFileURLs: [URL] = []
    public private(set) var sessionDirectoryURL: URL?

    private let outputDirectory: URL
    private let sampleRate: Double
    private let bitRate: Int
    private let outputFormat: AudioOutputFormat
    private let segmentFrameLimit: Int64
    private let fileManager: FileManager
    private let filenameGenerator: RecordingFilenameGenerator
    private let mp3Encoder: MP3Encoding

    private var currentFile: AVAudioFile?
    private var currentWriteURL: URL?
    private var currentFinalURL: URL?
    private var currentSegmentFrames: Int64 = 0
    private var segmentIndex = 1

    public init(
        settings: RecordingSettings,
        mode: RecordingMode,
        startedAt: Date = Date(),
        fileManager: FileManager = .default
    ) {
        self.outputDirectory = settings.outputDirectory
        self.sampleRate = settings.sampleRate
        self.bitRate = settings.bitRate
        self.outputFormat = settings.outputFormat
        self.segmentFrameLimit = max(1, Int64((settings.segmentDurationSeconds * settings.sampleRate).rounded()))
        self.fileManager = fileManager
        self.mp3Encoder = ExternalMP3Encoder(fileManager: fileManager)

        self.filenameGenerator = RecordingFilenameGenerator(
            startedAt: startedAt,
            mode: mode,
            sessionTitle: settings.sessionTitle,
            fileExtension: settings.outputFormat.fileExtension
        )
    }

    init(
        settings: RecordingSettings,
        mode: RecordingMode,
        startedAt: Date = Date(),
        fileManager: FileManager = .default,
        mp3Encoder: MP3Encoding
    ) {
        self.outputDirectory = settings.outputDirectory
        self.sampleRate = settings.sampleRate
        self.bitRate = settings.bitRate
        self.outputFormat = settings.outputFormat
        self.segmentFrameLimit = max(1, Int64((settings.segmentDurationSeconds * settings.sampleRate).rounded()))
        self.fileManager = fileManager
        self.mp3Encoder = mp3Encoder

        self.filenameGenerator = RecordingFilenameGenerator(
            startedAt: startedAt,
            mode: mode,
            sessionTitle: settings.sessionTitle,
            fileExtension: settings.outputFormat.fileExtension
        )
    }

    public func write(_ buffer: StereoPCMBuffer) throws {
        guard buffer.sampleRate == sampleRate else {
            throw RecorderError.invalidBuffer("書き込み対象のサンプルレートが録音設定と一致していません。")
        }

        var offsetFrame = 0
        while offsetFrame < buffer.frameCount {
            if currentFile == nil {
                try startNextSegment()
            }

            let remainingFramesInSegment = Int(max(1, segmentFrameLimit - currentSegmentFrames))
            let framesToWrite = min(remainingFramesInSegment, buffer.frameCount - offsetFrame)
            let slice = buffer.slice(startFrame: offsetFrame, frameCount: framesToWrite)
            let pcm = try slice.makeAVAudioPCMBuffer()
            try currentFile?.write(from: pcm)

            currentSegmentFrames += Int64(framesToWrite)
            offsetFrame += framesToWrite

            if currentSegmentFrames >= segmentFrameLimit {
                try closeCurrentSegment()
            }
        }
    }

    public func close() throws {
        try closeCurrentSegment()
    }

    private func startNextSegment() throws {
        let partsDirectory = try prepareSessionDirectoriesIfNeeded()

        let fileName = filenameGenerator.fileName(segmentIndex: segmentIndex)
        let finalURL = partsDirectory.appendingPathComponent(fileName)
        let writeURL = outputFormat.writesViaIntermediateM4A
            ? finalURL.deletingPathExtension().appendingPathExtension("tmp.m4a")
            : finalURL
        let settings = outputFormat.avAudioFileSettings(sampleRate: sampleRate, bitRate: bitRate)

        if outputFormat.writesViaIntermediateM4A {
            try? fileManager.removeItem(at: writeURL)
        }

        currentFile = try AVAudioFile(
            forWriting: writeURL,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        currentWriteURL = writeURL
        currentFinalURL = finalURL
        currentSegmentFrames = 0
        segmentIndex += 1
    }

    private func prepareSessionDirectoriesIfNeeded() throws -> URL {
        if let sessionDirectoryURL {
            return sessionDirectoryURL.appendingPathComponent("parts", isDirectory: true)
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let baseName = filenameGenerator.sessionDirectoryName

        for index in 1...9_999 {
            let directoryName = index == 1 ? baseName : baseName + String(format: "_%03d", index)
            let candidate = outputDirectory.appendingPathComponent(directoryName, isDirectory: true)
            guard !fileManager.fileExists(atPath: candidate.path) else {
                continue
            }

            do {
                // Claim the session name atomically before creating children so simultaneous starts cannot share it.
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                let partsDirectory = candidate.appendingPathComponent("parts", isDirectory: true)
                do {
                    try fileManager.createDirectory(at: partsDirectory, withIntermediateDirectories: false)
                } catch {
                    try? fileManager.removeItem(at: candidate)
                    throw error
                }
                sessionDirectoryURL = candidate
                return partsDirectory
            } catch CocoaError.fileWriteFileExists {
                // A simultaneous recording may claim the same name between the existence check and creation.
                continue
            }
        }

        throw RecorderError.fileWriteFailed("一意な録音セッションフォルダを作成できませんでした。")
    }

    private func closeCurrentSegment() throws {
        guard currentFile != nil else {
            return
        }

        currentFile?.close()
        defer {
            currentFile = nil
            currentWriteURL = nil
            currentFinalURL = nil
            currentSegmentFrames = 0
        }

        guard let writeURL = currentWriteURL, let finalURL = currentFinalURL else {
            return
        }

        if outputFormat.writesViaIntermediateM4A {
            try mp3Encoder.encodeM4A(sourceURL: writeURL, destinationURL: finalURL)
            try? fileManager.removeItem(at: writeURL)
        }

        completedFileURLs.append(finalURL)
    }
}
