import Testing
@testable import MeetingAudioCaptureCore

@Suite
struct InputAudioDiagnosticsTests {
    @Test
    func normalMicrophoneInputDoesNotWarn() throws {
        var diagnostics = InputAudioDiagnostics(mode: .inPerson)
        diagnostics.observe(try chunk(source: .microphone, samples: [0.05, -0.05]))

        #expect(diagnostics.finish().isEmpty)
    }

    @Test
    func silentMicrophoneWarnsOnlyOnce() throws {
        var diagnostics = InputAudioDiagnostics(mode: .inPerson)
        diagnostics.observe(try chunk(source: .microphone, samples: [0, 0]))

        let warnings = diagnostics.finish()

        #expect(warnings.map(\.source) == [.microphone])
        #expect(diagnostics.finish().isEmpty)
    }

    @Test
    func onlineMeetingDiagnosesSourcesIndependently() throws {
        var diagnostics = InputAudioDiagnostics(mode: .onlineMeeting)
        diagnostics.observe(try chunk(source: .system, samples: [0.1, -0.1]))
        diagnostics.observe(try chunk(source: .microphone, samples: [0.000_1, -0.000_1]))

        #expect(diagnostics.finish().map(\.source) == [.microphone])
    }

    @Test
    func missingExpectedBufferWarnsForThatSource() throws {
        var diagnostics = InputAudioDiagnostics(mode: .onlineMeeting)
        diagnostics.observe(try chunk(source: .microphone, samples: [0.1]))

        #expect(diagnostics.finish().map(\.source) == [.system])
    }

    private func chunk(source: AudioSourceKind, samples: [Float]) throws -> AudioChunk {
        try AudioChunk(
            source: source,
            startTimeSeconds: 0,
            sampleRate: 48_000,
            channels: [samples]
        )
    }
}
