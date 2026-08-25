@preconcurrency import AVFoundation
import Foundation

protocol MP3SegmentMerging {
    func merge(segments: [URL], destinationURL: URL) throws
}

struct ExternalMP3SegmentMerger: MP3SegmentMerging {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func merge(segments: [URL], destinationURL: URL) throws {
        guard let ffmpegURL = findFFmpeg() else {
            throw RecorderError.mp3EncoderUnavailable
        }

        let tempDirectory = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".MeetingAudioCapture-merge-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempDirectory)
        }

        var listLines: [String] = []
        for (index, sourceURL) in segments.enumerated() {
            let linkURL = tempDirectory.appendingPathComponent(String(format: "segment%03d.mp3", index + 1))
            try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: sourceURL)
            listLines.append("file '\(linkURL.lastPathComponent)'")
        }

        let listURL = tempDirectory.appendingPathComponent("segments.txt")
        let listBody = listLines.joined(separator: "\n").appending("\n")
        try listBody.write(to: listURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: destinationURL)

        try run(
            ffmpegURL,
            arguments: [
                "-y",
                "-hide_banner",
                "-loglevel", "error",
                "-f", "concat",
                "-safe", "0",
                "-i", listURL.path,
                "-c", "copy",
                destinationURL.path
            ]
        )
    }

    private func findFFmpeg() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        for path in candidates {
            if fileManager.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func run(_ executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw RecorderError.segmentMergeFailed(error.recorderDiagnosticMessage)
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnostic = message?.isEmpty == false
                ? message!
                : "ffmpegがステータス \(process.terminationStatus) で終了しました。"
            throw RecorderError.segmentMergeFailed(diagnostic)
        }
    }
}

struct AudioSegmentMerger {
    private let fileManager: FileManager
    private let mp3Merger: MP3SegmentMerging

    init(
        fileManager: FileManager = .default,
        mp3Merger: MP3SegmentMerging = ExternalMP3SegmentMerger()
    ) {
        self.fileManager = fileManager
        self.mp3Merger = mp3Merger
    }

    func merge(
        segments: [URL],
        outputFormat: AudioOutputFormat,
        deletesSourceSegmentsOnSuccess: Bool = false
    ) async throws -> URL? {
        guard segments.count > 1 else {
            return nil
        }

        let destinationURL = availableOutputURL(preferredURL: mergedOutputURL(for: segments[0]))

        do {
            switch outputFormat {
            case .m4a:
                try await mergeM4A(segments: segments, destinationURL: destinationURL)
            case .wav:
                try mergeWAV(segments: segments, destinationURL: destinationURL)
            case .mp3:
                try mp3Merger.merge(segments: segments, destinationURL: destinationURL)
            }
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        if deletesSourceSegmentsOnSuccess {
            deleteSourceSegments(segments, excluding: destinationURL)
        }

        return destinationURL
    }

    private func deleteSourceSegments(_ segments: [URL], excluding destinationURL: URL) {
        for segment in segments where segment.standardizedFileURL != destinationURL.standardizedFileURL {
            try? fileManager.removeItem(at: segment)
        }
    }

    func mergedOutputURL(for firstSegmentURL: URL) -> URL {
        let partsDirectory = firstSegmentURL.deletingLastPathComponent()
        let directory = partsDirectory.lastPathComponent == "parts"
            ? partsDirectory.deletingLastPathComponent()
            : partsDirectory
        let fileExtension = firstSegmentURL.pathExtension
        let baseName = firstSegmentURL.deletingPathExtension().lastPathComponent
        let mergedBaseName = baseName.replacingOccurrences(
            of: #"_part\d{3}$"#,
            with: "_merged",
            options: .regularExpression
        )
        let finalBaseName = mergedBaseName == baseName ? baseName + "_merged" : mergedBaseName
        return directory.appendingPathComponent(finalBaseName).appendingPathExtension(fileExtension)
    }

    private func availableOutputURL(preferredURL: URL) -> URL {
        guard fileManager.fileExists(atPath: preferredURL.path) else {
            return preferredURL
        }

        let directory = preferredURL.deletingLastPathComponent()
        let fileExtension = preferredURL.pathExtension
        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        for index in 2...9_999 {
            let candidate = directory
                .appendingPathComponent(baseName + String(format: "_%03d", index))
                .appendingPathExtension(fileExtension)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory
            .appendingPathComponent(baseName + "_\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
    }

    private func mergeM4A(segments: [URL], destinationURL: URL) async throws {
        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.segmentMergeFailed("AVMutableCompositionTrackを作成できませんでした。")
        }

        var insertionTime = CMTime.zero
        for segmentURL in segments {
            let asset = AVURLAsset(url: segmentURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let assetTrack = tracks.first else {
                throw RecorderError.segmentMergeFailed("音声トラックが見つかりません: \(segmentURL.lastPathComponent)")
            }
            let duration = try await asset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: assetTrack,
                at: insertionTime
            )
            insertionTime = CMTimeAdd(insertionTime, duration)
        }

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.segmentMergeFailed("M4Aエクスポータを作成できませんでした。")
        }

        do {
            try await exporter.export(to: destinationURL, as: .m4a)
        } catch {
            throw RecorderError.segmentMergeFailed(error.recorderDiagnosticMessage)
        }
    }

    private func mergeWAV(segments: [URL], destinationURL: URL) throws {
        guard let firstURL = segments.first else {
            return
        }

        let firstFile = try AVAudioFile(forReading: firstURL)
        let outputFile = try AVAudioFile(forWriting: destinationURL, settings: firstFile.fileFormat.settings)
        try append(contentsOf: firstFile, to: outputFile)

        for segmentURL in segments.dropFirst() {
            let inputFile = try AVAudioFile(forReading: segmentURL)
            guard inputFile.fileFormat.sampleRate == firstFile.fileFormat.sampleRate,
                  inputFile.fileFormat.channelCount == firstFile.fileFormat.channelCount else {
                throw RecorderError.segmentMergeFailed("WAVセグメントの形式が一致しません: \(segmentURL.lastPathComponent)")
            }
            try append(contentsOf: inputFile, to: outputFile)
        }
    }

    private func append(contentsOf inputFile: AVAudioFile, to outputFile: AVAudioFile) throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFile.processingFormat,
            frameCapacity: 16_384
        ) else {
            throw RecorderError.segmentMergeFailed("WAV結合用バッファを作成できませんでした。")
        }

        while inputFile.framePosition < inputFile.length {
            let remainingFrames = inputFile.length - inputFile.framePosition
            let framesToRead = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remainingFrames))
            try inputFile.read(into: buffer, frameCount: framesToRead)
            if buffer.frameLength > 0 {
                try outputFile.write(from: buffer)
            }
        }
    }
}
