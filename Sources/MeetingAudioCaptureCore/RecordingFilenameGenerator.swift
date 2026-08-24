import Foundation

public struct RecordingFilenameGenerator: Sendable {
    public var startedAt: Date
    public var mode: RecordingMode
    public var sessionTitle: String?
    public var fileExtension: String
    public var timeZone: TimeZone

    public init(
        startedAt: Date,
        mode: RecordingMode,
        sessionTitle: String? = nil,
        fileExtension: String = "m4a",
        timeZone: TimeZone = .current
    ) {
        self.startedAt = startedAt
        self.mode = mode
        self.sessionTitle = sessionTitle
        self.fileExtension = fileExtension
        self.timeZone = timeZone
    }

    public func fileName(segmentIndex: Int) -> String {
        let normalizedExtension = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return sessionDirectoryName
            + "_"
            + String(format: "part%03d", max(1, segmentIndex))
            + "."
            + normalizedExtension
    }

    public var sessionDirectoryName: String {
        var components = [
            "MeetingAudioCapture",
            timestamp,
            mode.filenameComponent
        ]

        if let title = Self.sanitizedTitle(sessionTitle) {
            components.append(title)
        }

        return components.joined(separator: "_")
    }

    public static func sanitizedTitle(_ title: String?) -> String? {
        guard let title else {
            return nil
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let disallowed = CharacterSet(charactersIn: "/:\\\n\r\t").union(.controlCharacters)
        let replaced = trimmed.unicodeScalars.map { scalar in
            disallowed.contains(scalar) ? "_" : String(scalar)
        }.joined()
        let collapsed = replaced.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        let sanitized = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ._"))

        return sanitized.isEmpty ? nil : sanitized
    }

    private var timestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: startedAt)
    }
}
