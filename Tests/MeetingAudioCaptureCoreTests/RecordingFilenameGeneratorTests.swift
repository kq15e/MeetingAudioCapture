import Foundation
import Testing
@testable import MeetingAudioCaptureCore

@Suite
struct RecordingFilenameGeneratorTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test
    func defaultFileNameIncludesAppNameTimestampModeAndSegment() {
        let generator = RecordingFilenameGenerator(
            startedAt: Date(timeIntervalSince1970: 0),
            mode: .onlineMeeting,
            timeZone: utc
        )

        let fileName = generator.fileName(segmentIndex: 1)

        #expect(fileName == "MeetingAudioCapture_1970-01-01_00-00-00_online-meeting_part001.m4a")
        #expect(generator.sessionDirectoryName == "MeetingAudioCapture_1970-01-01_00-00-00_online-meeting")
    }

    @Test
    func titleIsIncludedWhenPresent() {
        let generator = RecordingFilenameGenerator(
            startedAt: Date(timeIntervalSince1970: 0),
            mode: .inPerson,
            sessionTitle: "週次定例",
            timeZone: utc
        )

        let fileName = generator.fileName(segmentIndex: 12)

        #expect(fileName == "MeetingAudioCapture_1970-01-01_00-00-00_in-person_週次定例_part012.m4a")
        #expect(generator.sessionDirectoryName == "MeetingAudioCapture_1970-01-01_00-00-00_in-person_週次定例")
    }

    @Test
    func sanitizesUnsafeTitleCharacters() {
        let sanitized = RecordingFilenameGenerator.sanitizedTitle("  sales/report:week\n1  ")

        #expect(sanitized == "sales_report_week_1")
    }

    @Test
    func emptyTitleIsOmitted() {
        let generator = RecordingFilenameGenerator(
            startedAt: Date(timeIntervalSince1970: 0),
            mode: .onlineMeeting,
            sessionTitle: " \n ",
            timeZone: utc
        )

        let fileName = generator.fileName(segmentIndex: 0)

        #expect(fileName == "MeetingAudioCapture_1970-01-01_00-00-00_online-meeting_part001.m4a")
    }
}
