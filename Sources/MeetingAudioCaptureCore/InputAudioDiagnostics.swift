import Foundation

public struct InputAudioDiagnosticWarning: Equatable, Sendable {
    public let source: AudioSourceKind
    public let message: String

    public init(source: AudioSourceKind, message: String) {
        self.source = source
        self.message = message
    }
}

public struct InputAudioDiagnostics: Sendable {
    public static let durationSeconds: TimeInterval = 7
    public static let silenceThresholdDBFS = -60.0

    private struct Measurement: Sendable {
        var sampleCount = 0
        var sumOfSquares = 0.0
    }

    private let expectedSources: Set<AudioSourceKind>
    private var measurements: [AudioSourceKind: Measurement] = [:]
    private var isFinished = false

    public init(mode: RecordingMode) {
        expectedSources = mode == .onlineMeeting ? [.system, .microphone] : [.microphone]
    }

    public mutating func observe(_ chunk: AudioChunk) {
        guard !isFinished, expectedSources.contains(chunk.source) else {
            return
        }

        var measurement = measurements[chunk.source, default: Measurement()]
        for channel in chunk.channels {
            for sample in channel where sample.isFinite {
                measurement.sampleCount += 1
                let value = Double(sample)
                measurement.sumOfSquares += value * value
            }
        }
        measurements[chunk.source] = measurement
    }

    public mutating func finish() -> [InputAudioDiagnosticWarning] {
        guard !isFinished else {
            return []
        }
        isFinished = true

        return expectedSources.sorted { $0.rawValue < $1.rawValue }.compactMap { source in
            guard let measurement = measurements[source], measurement.sampleCount > 0 else {
                return InputAudioDiagnosticWarning(
                    source: source,
                    message: "\(source.displayName)の音声バッファを確認できませんでした。入力デバイスと音量を確認してください。"
                )
            }

            let rootMeanSquare = sqrt(measurement.sumOfSquares / Double(measurement.sampleCount))
            let levelDBFS = rootMeanSquare > 0 ? 20 * log10(rootMeanSquare) : -.infinity
            guard levelDBFS < Self.silenceThresholdDBFS else {
                return nil
            }

            return InputAudioDiagnosticWarning(
                source: source,
                message: "\(source.displayName)の入力が無音または非常に小さい状態です。録音は継続します。"
            )
        }
    }
}
