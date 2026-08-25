@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

@available(macOS 15.0, *)
public final class MeetingRecordingEngine: NSObject {
    public var onStateChange: ((RecorderState) -> Void)?
    public var onError: ((RecorderError) -> Void)?
    public var onInputWarnings: (([InputAudioDiagnosticWarning]) -> Void)?
    public var onFinished: (([URL]) -> Void)?

    private let captureQueue = DispatchQueue(label: "app.meeting-audio-capture.capture")
    private let converter = SampleBufferAudioConverter()
    private let segmentMerger = AudioSegmentMerger()

    private var state: RecorderState = .idle {
        didSet {
            onStateChange?(state)
        }
    }

    private var settings: RecordingSettings
    private var mixer: TimelineAudioMixer?
    private var writer: SegmentedAudioFileWriter?
    private var stream: SCStream?
    private var captureSession: AVCaptureSession?
    private var activeMode: RecordingMode?
    private var inputDiagnostics: InputAudioDiagnostics?
    private var diagnosticWorkItem: DispatchWorkItem?
    private var isPaused = false
    private var isHandlingFailure = false

    public init(settings: RecordingSettings = .downloadsDefault) {
        self.settings = settings
        super.init()
    }

    private func makeMixer(for settings: RecordingSettings) -> TimelineAudioMixer {
        TimelineAudioMixer(
            outputSampleRate: settings.sampleRate,
            latencySeconds: settings.mixerLatencySeconds
        )
    }

    public func start(
        mode: RecordingMode,
        microphoneDeviceID: String?,
        sessionTitle: String? = nil,
        recordingSettings: RecordingSettings? = nil
    ) async throws {
        guard case .idle = state else {
            return
        }

        let startedAt = Date()
        let activeSettings = recordingSettings ?? settings
        settings = activeSettings

        var writerSettings = activeSettings
        writerSettings.sessionTitle = sessionTitle
        let writer = SegmentedAudioFileWriter(settings: writerSettings, mode: mode, startedAt: startedAt)
        let mixer = makeMixer(for: activeSettings)

        await captureQueueAsync {
            self.writer = writer
            self.mixer = mixer
            self.activeMode = mode
            self.inputDiagnostics = InputAudioDiagnostics(mode: mode)
            self.isPaused = false
        }
        state = .diagnosing(mode: mode, startedAt: startedAt)

        do {
            switch mode {
            case .onlineMeeting:
                try await startScreenCapture(microphoneDeviceID: microphoneDeviceID)
            case .inPerson:
                try await startMicrophoneOnlyCapture(microphoneDeviceID: microphoneDeviceID)
            }
            scheduleDiagnosticCompletion(mode: mode, startedAt: startedAt)
        } catch {
            let recorderError = RecorderError.classified(error, fallback: RecorderError.screenCaptureFailed)
            await cleanupAfterFailedStart()
            state = .failed(message: recorderError.statusMessage)
            throw recorderError
        }
    }

    public func stop() async {
        guard state != .idle else {
            return
        }

        state = .stopping

        var stopError: RecorderError?
        if let stream {
            stopError = await stopScreenCapture(stream)
        }

        await stopMicrophoneOnlyCapture()

        let result = await closeRecording(flushPendingAudio: true)
        var files = result.files
        let finalError = stopError ?? result.error

        if let finalError {
            state = .failed(message: finalError.statusMessage)
            onError?(finalError)
        } else {
            do {
                files = try await mergeSegmentsIfNeeded(files)
            } catch {
                onError?(RecorderError.classified(error, fallback: RecorderError.segmentMergeFailed))
            }
            state = .idle
        }

        onFinished?(files)
    }

    public func pause() async {
        guard case .recording(let mode, let startedAt) = state else {
            return
        }

        let pausedAt = Date()

        do {
            try await captureQueueThrowing {
                guard !self.isPaused else {
                    return
                }

                guard let writer = self.writer else {
                    throw RecorderError.writerNotStarted
                }

                if let outputs = self.mixer?.finish() {
                    for output in outputs {
                        do {
                            try writer.write(output)
                        } catch {
                            throw RecorderError.classified(error, fallback: RecorderError.fileWriteFailed)
                        }
                    }
                }

                self.mixer = nil
                self.isPaused = true
            }

            state = .paused(mode: mode, startedAt: startedAt, pausedAt: pausedAt)
        } catch {
            await failRecording(
                RecorderError.classified(error, fallback: RecorderError.fileWriteFailed),
                flushPendingAudio: false
            )
        }
    }

    private func scheduleDiagnosticCompletion(mode: RecordingMode, startedAt: Date) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, var diagnostics = self.inputDiagnostics else {
                return
            }

            let warnings = diagnostics.finish()
            self.inputDiagnostics = diagnostics
            self.diagnosticWorkItem = nil

            guard case .diagnosing = self.state else {
                return
            }
            self.state = .recording(mode: mode, startedAt: startedAt)
            if !warnings.isEmpty {
                self.onInputWarnings?(warnings)
            }
        }
        diagnosticWorkItem = workItem
        captureQueue.asyncAfter(deadline: .now() + InputAudioDiagnostics.durationSeconds, execute: workItem)
    }

    public func resume() async {
        guard case .paused(let mode, let startedAt, let pausedAt) = state else {
            return
        }

        let resumedAt = Date()
        let adjustedStartedAt = startedAt.addingTimeInterval(resumedAt.timeIntervalSince(pausedAt))

        await captureQueueAsync {
            self.mixer = self.makeMixer(for: self.settings)
            self.isPaused = false
        }

        state = .recording(mode: mode, startedAt: adjustedStartedAt)
    }

    public func clearFailure() {
        guard case .failed = state else {
            return
        }
        state = .idle
    }

    private func startScreenCapture(microphoneDeviceID: String?) async throws {
        let content: SCShareableContent
        do {
            content = try await shareableContent()
        } catch {
            throw RecorderError.classified(error, fallback: RecorderError.screenCaptureFailed)
        }

        guard let display = content.displays.first else {
            throw RecorderError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.sampleRate = Int(settings.sampleRate)
        configuration.channelCount = Int(settings.channelCount)
        configuration.excludesCurrentProcessAudio = true
        if let microphoneDeviceID {
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: captureQueue)
        } catch {
            throw RecorderError.screenCaptureFailed(error.recorderDiagnosticMessage)
        }

        self.stream = stream
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: RecorderError.screenCaptureFailed(error.recorderDiagnosticMessage))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func startMicrophoneOnlyCapture(microphoneDeviceID: String?) async throws {
        do {
            try await captureQueueThrowing {
                guard let device = MicrophoneDeviceProvider.captureDevice(for: microphoneDeviceID) else {
                    throw RecorderError.noMicrophoneAvailable
                }

                let session = AVCaptureSession()
                session.beginConfiguration()

                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    throw RecorderError.noMicrophoneAvailable
                }
                session.addInput(input)

                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: self.captureQueue)
                guard session.canAddOutput(output) else {
                    throw RecorderError.noMicrophoneAvailable
                }
                session.addOutput(output)

                session.commitConfiguration()
                self.captureSession = session
                session.startRunning()
            }
        } catch {
            throw RecorderError.classified(error, fallback: RecorderError.microphoneCaptureFailed)
        }
    }

    private func stopScreenCapture(_ stream: SCStream) async -> RecorderError? {
        await withCheckedContinuation { continuation in
            stream.stopCapture { error in
                if let error {
                    continuation.resume(returning: RecorderError.stopFailed(error.recorderDiagnosticMessage))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func stopMicrophoneOnlyCapture() async {
        await captureQueueAsync {
            self.captureSession?.stopRunning()
        }
    }

    private func cleanupAfterFailedStart() async {
        if let stream {
            _ = await stopScreenCapture(stream)
        }

        await captureQueueAsync {
            self.captureSession?.stopRunning()
            self.captureSession = nil
            self.stream = nil
            try? self.writer?.close()
            self.writer = nil
            self.mixer = nil
            self.activeMode = nil
            self.diagnosticWorkItem?.cancel()
            self.diagnosticWorkItem = nil
            self.inputDiagnostics = nil
            self.isPaused = false
            self.isHandlingFailure = false
        }
    }

    private func mergeSegmentsIfNeeded(_ files: [URL]) async throws -> [URL] {
        guard settings.mergeSegmentsAfterRecording else {
            return files
        }

        guard let mergedURL = try await segmentMerger.merge(
            segments: files,
            outputFormat: settings.outputFormat,
            deletesSourceSegmentsOnSuccess: true
        ) else {
            return files
        }
        return [mergedURL]
    }

    private func closeRecording(flushPendingAudio: Bool) async -> (files: [URL], error: RecorderError?) {
        await captureQueueAsync {
            var closeError: RecorderError?

            if flushPendingAudio, let outputs = self.mixer?.finish() {
                guard let writer = self.writer else {
                    closeError = .writerNotStarted
                    return ([], closeError)
                }

                for output in outputs {
                    do {
                        try writer.write(output)
                    } catch {
                        closeError = closeError ?? RecorderError.classified(error, fallback: RecorderError.fileWriteFailed)
                    }
                }
            }

            do {
                try self.writer?.close()
            } catch {
                closeError = closeError ?? RecorderError.classified(error, fallback: RecorderError.fileWriteFailed)
            }
            let urls = self.writer?.completedFileURLs ?? []
            self.writer = nil
            self.mixer = nil
            self.stream = nil
            self.captureSession = nil
            self.activeMode = nil
            self.diagnosticWorkItem?.cancel()
            self.diagnosticWorkItem = nil
            self.inputDiagnostics = nil
            self.isPaused = false
            return (urls, closeError)
        }
    }

    private func shareableContent() async throws -> SCShareableContent {
        try await withCheckedThrowingContinuation { continuation in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error {
                    continuation.resume(throwing: RecorderError.screenCaptureFailed(error.recorderDiagnosticMessage))
                    return
                }
                guard let content else {
                    continuation.resume(throwing: RecorderError.noDisplayAvailable)
                    return
                }
                continuation.resume(returning: content)
            }
        }
    }

    private func process(sampleBuffer: CMSampleBuffer, source: AudioSourceKind) {
        guard !isPaused else {
            return
        }

        let chunk: AudioChunk
        do {
            chunk = try converter.chunk(from: sampleBuffer, source: source)
        } catch {
            handleRuntimeFailure(
                .audioConversionFailed(
                    "対象入力: \(source.displayName)\n入力形式: \(audioFormatSummary(for: sampleBuffer))\n\(error.recorderDiagnosticMessage)"
                ),
                flushPendingAudio: true
            )
            return
        }

        inputDiagnostics?.observe(chunk)

        let outputs = mixer?.append(chunk) ?? []
        for output in outputs {
            guard let writer else {
                handleRuntimeFailure(.writerNotStarted, flushPendingAudio: false)
                return
            }

            do {
                try writer.write(output)
            } catch {
                handleRuntimeFailure(
                    RecorderError.classified(error, fallback: RecorderError.fileWriteFailed),
                    flushPendingAudio: false
                )
                return
            }
        }
    }

    private func audioFormatSummary(for sampleBuffer: CMSampleBuffer) -> String {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let pointer = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return "取得不能"
        }
        let format = pointer.pointee
        return "formatID=\(format.mFormatID), sampleRate=\(format.mSampleRate), channels=\(format.mChannelsPerFrame), bits=\(format.mBitsPerChannel), flags=0x\(String(format.mFormatFlags, radix: 16))"
    }

    private func handleRuntimeFailure(_ error: RecorderError, flushPendingAudio: Bool) {
        Task {
            await failRecording(error, flushPendingAudio: flushPendingAudio)
        }
    }

    private func failRecording(_ error: RecorderError, flushPendingAudio: Bool) async {
        guard !isHandlingFailure else {
            return
        }
        isHandlingFailure = true

        guard state != .idle else {
            isHandlingFailure = false
            return
        }

        state = .stopping

        if let stream {
            _ = await stopScreenCapture(stream)
        }
        await stopMicrophoneOnlyCapture()

        let result = await closeRecording(flushPendingAudio: flushPendingAudio)
        let finalError = result.error ?? error

        state = .failed(message: finalError.statusMessage)
        isHandlingFailure = false
        onError?(finalError)

        if !result.files.isEmpty {
            onFinished?(result.files)
        }
    }

    private func captureQueueAsync<T>(_ operation: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                continuation.resume(returning: operation())
            }
        }
    }

    private func captureQueueThrowing<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            captureQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@available(macOS 15.0, *)
extension MeetingRecordingEngine: SCStreamOutput, SCStreamDelegate {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            process(sampleBuffer: sampleBuffer, source: .system)
        case .microphone:
            process(sampleBuffer: sampleBuffer, source: .microphone)
        default:
            break
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        handleRuntimeFailure(.captureInterrupted(error.recorderDiagnosticMessage), flushPendingAudio: true)
    }
}

@available(macOS 15.0, *)
extension MeetingRecordingEngine: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        process(sampleBuffer: sampleBuffer, source: .microphone)
    }
}
