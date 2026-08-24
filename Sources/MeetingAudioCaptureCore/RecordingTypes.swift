import Foundation

public enum RecordingMode: String, CaseIterable, Sendable {
    case onlineMeeting
    case inPerson

    public var displayName: String {
        switch self {
        case .onlineMeeting:
            return "オンライン会議"
        case .inPerson:
            return "対面"
        }
    }

    public var capturesSystemAudio: Bool {
        self == .onlineMeeting
    }

    public var filenameComponent: String {
        switch self {
        case .onlineMeeting:
            return "online-meeting"
        case .inPerson:
            return "in-person"
        }
    }
}

public enum AudioSourceKind: String, Hashable, Sendable {
    case system
    case microphone

    public var displayName: String {
        switch self {
        case .system:
            return "システム音声"
        case .microphone:
            return "マイク"
        }
    }
}

public enum AudioOutputFormat: String, CaseIterable, Sendable {
    case m4a
    case wav
    case mp3

    public var displayName: String {
        switch self {
        case .m4a:
            return "M4A (AAC)"
        case .wav:
            return "WAV (PCM)"
        case .mp3:
            return "MP3"
        }
    }

    public var fileExtension: String {
        rawValue
    }
}

public struct RecordingSettings: Sendable {
    public var outputDirectory: URL
    public var sampleRate: Double
    public var channelCount: Int
    public var bitRate: Int
    public var outputFormat: AudioOutputFormat
    public var mergeSegmentsAfterRecording: Bool
    public var segmentDurationSeconds: TimeInterval
    public var mixerLatencySeconds: TimeInterval
    public var sessionTitle: String?

    public init(
        outputDirectory: URL,
        sampleRate: Double = 48_000,
        channelCount: Int = 2,
        bitRate: Int = 192_000,
        outputFormat: AudioOutputFormat = .m4a,
        mergeSegmentsAfterRecording: Bool = false,
        segmentDurationSeconds: TimeInterval = 30 * 60,
        mixerLatencySeconds: TimeInterval = 0.35,
        sessionTitle: String? = nil
    ) {
        self.outputDirectory = outputDirectory
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitRate = bitRate
        self.outputFormat = outputFormat
        self.mergeSegmentsAfterRecording = mergeSegmentsAfterRecording
        self.segmentDurationSeconds = segmentDurationSeconds
        self.mixerLatencySeconds = mixerLatencySeconds
        self.sessionTitle = sessionTitle
    }

    public static var downloadsDefault: RecordingSettings {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return RecordingSettings(outputDirectory: downloads)
    }
}

public struct MicrophoneDevice: Identifiable, Equatable, Sendable {
    public let id: String?
    public let name: String

    public init(id: String?, name: String) {
        self.id = id
        self.name = name
    }

    public static let systemDefault = MicrophoneDevice(id: nil, name: "システム標準")
}

public enum RecorderState: Equatable, Sendable {
    case idle
    case diagnosing(mode: RecordingMode, startedAt: Date)
    case recording(mode: RecordingMode, startedAt: Date)
    case paused(mode: RecordingMode, startedAt: Date, pausedAt: Date)
    case stopping
    case failed(message: String)
}

public enum RecorderError: LocalizedError, Equatable, Sendable {
    case noDisplayAvailable
    case noMicrophoneAvailable
    case permissionDenied(String)
    case screenCaptureFailed(String)
    case microphoneCaptureFailed(String)
    case captureInterrupted(String)
    case fileWriteFailed(String)
    case audioConversionFailed(String)
    case unsupportedAudioFormat(String)
    case writerNotStarted
    case invalidBuffer(String)
    case mp3EncoderUnavailable
    case mp3EncodingFailed(String)
    case segmentMergeFailed(String)
    case stopFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "録音対象にできるディスプレイが見つかりません。"
        case .noMicrophoneAvailable:
            return "利用できるマイクが見つかりません。"
        case .permissionDenied(let message):
            return message
        case .screenCaptureFailed(let message):
            return "画面収録の開始に失敗しました。\n\(message)"
        case .microphoneCaptureFailed(let message):
            return "マイク録音の開始に失敗しました。\n\(message)"
        case .captureInterrupted(let message):
            return "録音中に音声取得が停止しました。\n\(message)"
        case .fileWriteFailed(let message):
            return "音声ファイルの書き込みに失敗しました。\n\(message)"
        case .audioConversionFailed(let message):
            return "音声データの変換に失敗しました。\n\(message)"
        case .unsupportedAudioFormat(let message):
            return message
        case .writerNotStarted:
            return "音声ファイルの書き込みを開始できていません。"
        case .invalidBuffer(let message):
            return message
        case .mp3EncoderUnavailable:
            return "MP3変換に必要な ffmpeg が見つかりません。"
        case .mp3EncodingFailed(let message):
            return "MP3変換に失敗しました。\n\(message)"
        case .segmentMergeFailed(let message):
            return "分割ファイルの結合に失敗しました。\n\(message)"
        case .stopFailed(let message):
            return "録音停止処理で問題が発生しました。\n\(message)"
        }
    }

    public var alertTitle: String {
        switch self {
        case .permissionDenied:
            return "権限が必要です"
        case .noDisplayAvailable, .screenCaptureFailed:
            return "画面収録を開始できません"
        case .noMicrophoneAvailable, .microphoneCaptureFailed:
            return "マイクを使用できません"
        case .captureInterrupted:
            return "録音が中断されました"
        case .fileWriteFailed:
            return "ファイル保存に失敗しました"
        case .audioConversionFailed, .unsupportedAudioFormat, .invalidBuffer:
            return "音声処理に失敗しました"
        case .mp3EncoderUnavailable, .mp3EncodingFailed:
            return "MP3変換に失敗しました"
        case .segmentMergeFailed:
            return "分割ファイルを結合できません"
        case .writerNotStarted:
            return "録音ファイルを作成できません"
        case .stopFailed:
            return "録音停止に失敗しました"
        }
    }

    public var recoverySuggestion: String {
        switch self {
        case .permissionDenied:
            return "システム設定でマイク権限と画面収録権限を確認し、必要に応じてアプリを再起動してください。"
        case .noDisplayAvailable, .screenCaptureFailed:
            return "画面収録権限を確認し、外部ディスプレイ接続中なら一度接続状態を確認してから再試行してください。"
        case .noMicrophoneAvailable, .microphoneCaptureFailed:
            return "マイクの接続とmacOSの入力設定を確認し、別のマイクを選んで再試行してください。"
        case .captureInterrupted:
            return "途中まで保存できたファイルは残します。アプリの状態をクリアしてから再試行してください。"
        case .fileWriteFailed:
            return "保存先の空き容量と書き込み権限を確認し、保存先を変更してから再試行してください。途中まで保存できたファイルは残します。"
        case .audioConversionFailed, .unsupportedAudioFormat, .invalidBuffer:
            return "音声デバイスや会議アプリの入出力設定を確認し、録音をやり直してください。"
        case .mp3EncoderUnavailable:
            return "Homebrewなどで ffmpeg をインストールするか、保存形式をM4A/WAVに変更して再試行してください。"
        case .mp3EncodingFailed:
            return "一時M4Aファイルが残っている可能性があります。保存先を確認し、保存形式をM4A/WAVに変更して再試行してください。"
        case .segmentMergeFailed:
            return "元の分割ファイルは残っています。保存先を確認し、必要なら手動で結合してください。"
        case .writerNotStarted:
            return "保存先を変更してから再試行してください。"
        case .stopFailed:
            return "保存済みファイルを確認し、アプリの状態をクリアしてから再試行してください。"
        }
    }

    public var statusMessage: String {
        errorDescription ?? "録音エラーが発生しました。"
    }

    public var displayMessage: String {
        "\(statusMessage)\n\n次の対応:\n\(recoverySuggestion)"
    }

    public static func classified(_ error: Error, fallback: (String) -> RecorderError) -> RecorderError {
        if let recorderError = error as? RecorderError {
            return recorderError
        }
        return fallback(error.recorderDiagnosticMessage)
    }
}

extension Error {
    var recorderDiagnosticMessage: String {
        let message = localizedDescription
        guard !message.isEmpty else {
            return String(describing: self)
        }
        return message
    }
}
