import Testing
@testable import MeetingAudioCaptureCore

@Suite
struct TimelineAudioMixerTests {
    @Test
    func overlappingSystemAndMicrophoneChunksAreMixed() throws {
        let mixer = TimelineAudioMixer(outputSampleRate: 48_000, latencySeconds: 1)
        let system = try AudioChunk(
            source: .system,
            startTimeSeconds: 10,
            sampleRate: 48_000,
            channels: [[0.25, 0.25], [0.10, 0.10]]
        )
        let microphone = try AudioChunk(
            source: .microphone,
            startTimeSeconds: 10,
            sampleRate: 48_000,
            channels: [[0.25, 0.25]]
        )

        #expect(mixer.append(system).isEmpty)
        #expect(mixer.append(microphone).isEmpty)
        let output = mixer.finish()

        #expect(output.count == 1)
        expectSamples(output[0].interleavedSamples, [0.5, 0.35, 0.5, 0.35])
    }

    @Test
    func mixerClipsInsteadOfOverflowing() throws {
        let mixer = TimelineAudioMixer(outputSampleRate: 48_000, latencySeconds: 1)
        let system = try AudioChunk(
            source: .system,
            startTimeSeconds: 0,
            sampleRate: 48_000,
            channels: [[0.75], [0.75]]
        )
        let microphone = try AudioChunk(
            source: .microphone,
            startTimeSeconds: 0,
            sampleRate: 48_000,
            channels: [[0.75]]
        )

        _ = mixer.append(system)
        _ = mixer.append(microphone)
        let output = mixer.finish()

        expectSamples(output[0].interleavedSamples, [1.0, 1.0])
    }

    @Test
    func lateChunkAlreadyPastCursorIsIgnored() throws {
        let mixer = TimelineAudioMixer(outputSampleRate: 48_000, latencySeconds: 0)
        let firstSamples = Array(repeating: Float(0.1), count: 256)
        let first = try AudioChunk(
            source: .system,
            startTimeSeconds: 0,
            sampleRate: 48_000,
            channels: [firstSamples, firstSamples]
        )
        let late = try AudioChunk(
            source: .microphone,
            startTimeSeconds: 0,
            sampleRate: 48_000,
            channels: [[0.9, 0.9, 0.9]]
        )

        let firstOutput = mixer.append(first)
        _ = mixer.append(late)
        let finalOutput = mixer.finish()

        let expectedFirstOutput = Array(repeating: [Float(0.1), Float(0.1)], count: 256).flatMap { $0 }
        expectSamples(firstOutput.first?.interleavedSamples ?? [], expectedFirstOutput)
        #expect(finalOutput.isEmpty)
    }

    @Test
    func freshMixerAfterPauseDoesNotInsertPausedSilence() throws {
        let firstMixer = TimelineAudioMixer(outputSampleRate: 10, latencySeconds: 0, maxSilentGapSeconds: 5)
        let first = try AudioChunk(
            source: .system,
            startTimeSeconds: 0,
            sampleRate: 10,
            channels: [[0.1, 0.2], [0.1, 0.2]]
        )

        _ = firstMixer.append(first)
        let firstOutput = firstMixer.finish()
        expectSamples(firstOutput.first?.interleavedSamples ?? [], [0.1, 0.1, 0.2, 0.2])

        let resumedMixer = TimelineAudioMixer(outputSampleRate: 10, latencySeconds: 0, maxSilentGapSeconds: 5)
        let afterPause = try AudioChunk(
            source: .microphone,
            startTimeSeconds: 2,
            sampleRate: 10,
            channels: [[0.3, 0.4]]
        )

        _ = resumedMixer.append(afterPause)
        let resumedOutput = resumedMixer.finish()
        expectSamples(resumedOutput.first?.interleavedSamples ?? [], [0.3, 0.3, 0.4, 0.4])
    }

}
