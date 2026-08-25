import AVFAudio
import Foundation

public struct SavedAudioSegmentMergePlan: Equatable, Sendable {
    public let sessionDirectory: URL
    public let segments: [URL]
    public let outputFormat: AudioOutputFormat
    public let missingSegmentIndices: [Int]
    public let existingMergedFiles: [URL]
}

public enum SavedAudioSegmentMergeError: LocalizedError, Equatable, Sendable {
    case partsDirectoryNotFound
    case noSegmentsFound
    case onlyOneSegment
    case mixedOutputFormats
    case mixedRecordingNames
    case duplicateSegmentNumber(Int)
    case invalidWAV(String)
    case inconsistentWAVFormat(String)
    case mergeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .partsDirectoryNotFound:
            return "選択したフォルダにpartsフォルダが見つかりません。"
        case .noSegmentsFound:
            return "結合できるpartファイルが見つかりません。"
        case .onlyOneSegment:
            return "partファイルが1つだけのため結合できません。"
        case .mixedOutputFormats:
            return "異なる保存形式のpartファイルが混在しています。"
        case .mixedRecordingNames:
            return "異なる録音のpartファイルが混在しています。"
        case .duplicateSegmentNumber(let number):
            return String(format: "part%03dが重複しています。", number)
        case .invalidWAV(let message):
            return "WAVファイルを検証できません。\n\(message)"
        case .inconsistentWAVFormat(let fileName):
            return "WAVのサンプルレートまたはチャンネル数が一致しません: \(fileName)"
        case .mergeFailed(let message):
            return "分割ファイルを結合できませんでした。\n\(message)"
        }
    }
}

public struct SavedAudioSegmentMerger {
    private struct Segment: Sendable {
        let url: URL
        let baseName: String
        let index: Int
        let outputFormat: AudioOutputFormat
    }

    private let fileManager: FileManager
    private let merger: AudioSegmentMerger

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.merger = AudioSegmentMerger(fileManager: fileManager)
    }

    public func makePlan(selectedDirectory: URL) throws -> SavedAudioSegmentMergePlan {
        let selectedDirectory = selectedDirectory.standardizedFileURL
        let partsDirectory: URL
        let sessionDirectory: URL
        if selectedDirectory.lastPathComponent == "parts" {
            partsDirectory = selectedDirectory
            sessionDirectory = selectedDirectory.deletingLastPathComponent()
        } else {
            sessionDirectory = selectedDirectory
            partsDirectory = selectedDirectory.appendingPathComponent("parts", isDirectory: true)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: partsDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SavedAudioSegmentMergeError.partsDirectoryNotFound
        }

        let urls = try fileManager.contentsOfDirectory(
            at: partsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let segments = urls.compactMap(segment(from:)).sorted { lhs, rhs in
            if lhs.index == rhs.index {
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            return lhs.index < rhs.index
        }

        guard !segments.isEmpty else {
            throw SavedAudioSegmentMergeError.noSegmentsFound
        }
        guard segments.count > 1 else {
            throw SavedAudioSegmentMergeError.onlyOneSegment
        }

        let formats = Set(segments.map(\.outputFormat))
        guard formats.count == 1, let outputFormat = formats.first else {
            throw SavedAudioSegmentMergeError.mixedOutputFormats
        }
        let baseNames = Set(segments.map(\.baseName))
        guard baseNames.count == 1, let baseName = baseNames.first else {
            throw SavedAudioSegmentMergeError.mixedRecordingNames
        }

        let groupedIndices = Dictionary(grouping: segments, by: \.index)
        if let duplicate = groupedIndices.first(where: { $0.value.count > 1 })?.key {
            throw SavedAudioSegmentMergeError.duplicateSegmentNumber(duplicate)
        }

        if outputFormat == .wav {
            try validateWAVFormats(segments.map(\.url))
        }

        let maximumIndex = segments.map(\.index).max() ?? 0
        let presentIndices = Set(segments.map(\.index))
        let missingIndices = maximumIndex > 0
            ? (1...maximumIndex).filter { !presentIndices.contains($0) }
            : []
        let existingMergedFiles = try existingMergedFiles(
            in: sessionDirectory,
            baseName: baseName,
            outputFormat: outputFormat
        )

        return SavedAudioSegmentMergePlan(
            sessionDirectory: sessionDirectory,
            segments: segments.map(\.url),
            outputFormat: outputFormat,
            missingSegmentIndices: missingIndices,
            existingMergedFiles: existingMergedFiles
        )
    }

    public func merge(_ plan: SavedAudioSegmentMergePlan) async throws -> URL {
        do {
            guard let outputURL = try await merger.merge(
                segments: plan.segments,
                outputFormat: plan.outputFormat
            ) else {
                throw SavedAudioSegmentMergeError.onlyOneSegment
            }
            return outputURL
        } catch let error as SavedAudioSegmentMergeError {
            throw error
        } catch {
            throw SavedAudioSegmentMergeError.mergeFailed(error.localizedDescription)
        }
    }

    private func segment(from url: URL) -> Segment? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return nil
        }
        let fileName = url.lastPathComponent
        let pattern = #"^(.+)_part(\d{3})\.(m4a|wav|mp3)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        guard let match = expression.firstMatch(in: fileName, range: range), match.numberOfRanges == 4,
              let baseRange = Range(match.range(at: 1), in: fileName),
              let indexRange = Range(match.range(at: 2), in: fileName),
              let formatRange = Range(match.range(at: 3), in: fileName),
              let index = Int(fileName[indexRange]), index > 0,
              let outputFormat = AudioOutputFormat(rawValue: fileName[formatRange].lowercased()) else {
            return nil
        }
        return Segment(
            url: url,
            baseName: String(fileName[baseRange]),
            index: index,
            outputFormat: outputFormat
        )
    }

    private func validateWAVFormats(_ urls: [URL]) throws {
        do {
            let firstFile = try AVAudioFile(forReading: urls[0])
            let sampleRate = firstFile.fileFormat.sampleRate
            let channelCount = firstFile.fileFormat.channelCount
            for url in urls.dropFirst() {
                let file = try AVAudioFile(forReading: url)
                guard file.fileFormat.sampleRate == sampleRate,
                      file.fileFormat.channelCount == channelCount else {
                    throw SavedAudioSegmentMergeError.inconsistentWAVFormat(url.lastPathComponent)
                }
            }
        } catch let error as SavedAudioSegmentMergeError {
            throw error
        } catch {
            throw SavedAudioSegmentMergeError.invalidWAV(error.localizedDescription)
        }
    }

    private func existingMergedFiles(
        in sessionDirectory: URL,
        baseName: String,
        outputFormat: AudioOutputFormat
    ) throws -> [URL] {
        let escapedBaseName = NSRegularExpression.escapedPattern(for: baseName)
        let escapedExtension = NSRegularExpression.escapedPattern(for: outputFormat.fileExtension)
        let expression = try NSRegularExpression(
            pattern: "^\(escapedBaseName)_merged(?:_\\d{3})?\\.\(escapedExtension)$",
            options: [.caseInsensitive]
        )
        return try fileManager.contentsOfDirectory(
            at: sessionDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let fileName = url.lastPathComponent
            let range = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
            return expression.firstMatch(in: fileName, range: range) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
