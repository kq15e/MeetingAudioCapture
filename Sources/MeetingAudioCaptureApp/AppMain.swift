import AppKit
import Foundation
import MeetingAudioCaptureCore

@main
enum MeetingAudioCaptureApp {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@available(macOS 15.0, *)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let engine = MeetingRecordingEngine()
    private let outputDirectoryStore = OutputDirectoryStore()
    private let audioOutputFormatStore = AudioOutputFormatStore()
    private let segmentMergePreferenceStore = SegmentMergePreferenceStore()

    private var selectedMode: RecordingMode = .onlineMeeting
    private var selectedMicrophoneID: String?
    private var recorderState: RecorderState = .idle
    private var latestFiles: [URL] = []
    private var selectedOutputDirectory = OutputDirectoryStore.downloadsDirectory
    private var selectedOutputFormat: AudioOutputFormat = .m4a
    private var mergeSegmentsAfterRecording = false
    private var recordingTitle = ""
    private var statusRefreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        loadOutputDirectory()
        loadOutputFormat()
        loadSegmentMergePreference()
        configureEngineCallbacks()
        rebuildMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStatusRefreshTimer()
    }

    private func loadOutputDirectory() {
        let resolution = outputDirectoryStore.loadOutputDirectory()
        selectedOutputDirectory = resolution.outputDirectory

        guard resolution.didFallback else {
            return
        }

        outputDirectoryStore.clearOutputDirectory()
        DispatchQueue.main.async { [weak self] in
            self?.showOutputDirectoryFallbackAlert(attemptedDirectory: resolution.attemptedDirectory)
        }
    }

    private func loadOutputFormat() {
        selectedOutputFormat = audioOutputFormatStore.loadOutputFormat()
    }

    private func loadSegmentMergePreference() {
        mergeSegmentsAfterRecording = segmentMergePreferenceStore.loadMergeSegmentsAfterRecording()
    }

    private func recordingSettingsForCurrentSelection() -> RecordingSettings {
        let outputDirectory = resolvedOutputDirectoryForRecording()
        return RecordingSettings(
            outputDirectory: outputDirectory,
            outputFormat: selectedOutputFormat,
            mergeSegmentsAfterRecording: mergeSegmentsAfterRecording
        )
    }

    private func resolvedOutputDirectoryForRecording() -> URL {
        guard outputDirectoryStore.isUsableDirectory(selectedOutputDirectory) else {
            selectedOutputDirectory = OutputDirectoryStore.downloadsDirectory
            outputDirectoryStore.clearOutputDirectory()
            rebuildMenu()
            showOutputDirectoryFallbackAlert(attemptedDirectory: nil)
            return selectedOutputDirectory
        }

        return selectedOutputDirectory
    }

    private func showOutputDirectoryFallbackAlert(attemptedDirectory: URL?) {
        let attemptedPath = attemptedDirectory.map { "\n元の保存先: \($0.path)" } ?? ""
        showAlert(
            title: "保存先をDownloadsに戻しました",
            message: "保存先が存在しないか、書き込めません。\n現在の保存先: \(OutputDirectoryStore.downloadsDirectory.path)\(attemptedPath)"
        )
    }

    private func abbreviatedPath(for directory: URL) -> String {
        let path = directory.standardizedFileURL.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

        if path == homePath {
            return "~"
        }

        if path.hasPrefix(homePath + "/") {
            return "~" + String(path.dropFirst(homePath.count))
        }

        return path
    }

    private func configureStatusItem() {
        setStatusTitle("REC")
        statusItem.button?.toolTip = "MeetingAudioCapture"
    }

    private func setStatusTitle(_ title: String) {
        statusItem.button?.title = title

        let font = statusItem.button?.font ?? NSFont.menuBarFont(ofSize: 0)
        let width = (title as NSString).size(withAttributes: [NSAttributedString.Key.font: font]).width
        statusItem.length = max(44, ceil(width) + 24)
    }

    private func configureEngineCallbacks() {
        engine.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.recorderState = state
                self?.updateStatusTitle()
                self?.syncStatusRefreshTimer()
                self?.rebuildMenu()
            }
        }

        engine.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.showAlert(title: error.alertTitle, message: error.displayMessage)
            }
        }

        engine.onInputWarnings = { [weak self] warnings in
            DispatchQueue.main.async {
                self?.showAlert(
                    title: "入力音声を確認してください",
                    message: warnings.map(\.message).joined(separator: "\n\n")
                )
            }
        }

        engine.onFinished = { [weak self] files in
            DispatchQueue.main.async {
                self?.latestFiles = files
                self?.showAlert(
                    title: self?.finishedAlertTitle ?? "録音を保存しました",
                    message: files.isEmpty ? "保存されたファイルはありません。" : files.map(\.lastPathComponent).joined(separator: "\n")
                )
            }
        }
    }

    private func updateStatusTitle() {
        switch recorderState {
        case .diagnosing:
            setStatusTitle("確認中")
        case .recording(_, let startedAt):
            let elapsed = RecordingElapsedTimeFormatter.string(startedAt: startedAt)
            setStatusTitle("REC \(elapsed)")
        case .paused(_, let startedAt, let pausedAt):
            let elapsed = RecordingElapsedTimeFormatter.string(startedAt: startedAt, now: pausedAt)
            setStatusTitle("PAUSE \(elapsed)")
        case .stopping:
            setStatusTitle("停止中")
        case .failed:
            setStatusTitle("ERR")
        case .idle:
            setStatusTitle("REC")
        }
    }

    private func syncStatusRefreshTimer() {
        guard case .recording = recorderState else {
            stopStatusRefreshTimer()
            return
        }

        guard statusRefreshTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            self.updateStatusTitle()
            self.rebuildMenu()
        }
        RunLoop.main.add(timer, forMode: .common)
        statusRefreshTimer = timer
    }

    private func stopStatusRefreshTimer() {
        statusRefreshTimer?.invalidate()
        statusRefreshTimer = nil
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(NSMenuItem.separator())

        let startStopTitle = isRecording ? "録音停止" : (isFailed ? "再試行" : "録音開始")
        menu.addItem(NSMenuItem(title: startStopTitle, action: #selector(toggleRecording), keyEquivalent: "r"))
        if canTogglePause {
            let pauseTitle = isPaused ? "録音再開" : "一時停止"
            menu.addItem(NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "p"))
        }
        if isFailed {
            menu.addItem(NSMenuItem(title: "エラーをクリア", action: #selector(clearRecorderError), keyEquivalent: "e"))
        }
        menu.addItem(NSMenuItem.separator())

        let modeMenuItem = NSMenuItem(title: "録音モード", action: nil, keyEquivalent: "")
        let modeMenu = NSMenu()
        for mode in RecordingMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(selectMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.state = selectedMode == mode ? .on : .off
            item.isEnabled = !isRecording
            modeMenu.addItem(item)
        }
        modeMenuItem.submenu = modeMenu
        menu.addItem(modeMenuItem)

        let microphoneMenuItem = NSMenuItem(title: "マイク", action: nil, keyEquivalent: "")
        let microphoneMenu = NSMenu()
        for device in MicrophoneDeviceProvider.availableInputDevices() {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.representedObject = device.id
            item.state = selectedMicrophoneID == device.id ? .on : .off
            item.isEnabled = !isRecording
            microphoneMenu.addItem(item)
        }
        microphoneMenuItem.submenu = microphoneMenu
        menu.addItem(microphoneMenuItem)

        menu.addItem(NSMenuItem.separator())
        let titleSummary = NSMenuItem(title: recordingTitleMenuTitle, action: nil, keyEquivalent: "")
        titleSummary.isEnabled = false
        menu.addItem(titleSummary)

        let setTitleItem = NSMenuItem(title: "録音タイトルを設定...", action: #selector(setRecordingTitle), keyEquivalent: "t")
        setTitleItem.isEnabled = !isRecording
        menu.addItem(setTitleItem)

        if RecordingFilenameGenerator.sanitizedTitle(recordingTitle) != nil {
            let clearTitleItem = NSMenuItem(title: "録音タイトルをクリア", action: #selector(clearRecordingTitle), keyEquivalent: "")
            clearTitleItem.isEnabled = !isRecording
            menu.addItem(clearTitleItem)
        }

        menu.addItem(NSMenuItem.separator())
        let outputDirectorySummary = NSMenuItem(title: outputDirectoryMenuTitle, action: nil, keyEquivalent: "")
        outputDirectorySummary.isEnabled = false
        outputDirectorySummary.toolTip = selectedOutputDirectory.path
        menu.addItem(outputDirectorySummary)

        let selectOutputDirectoryItem = NSMenuItem(title: "保存先を選択...", action: #selector(selectOutputDirectory), keyEquivalent: "s")
        selectOutputDirectoryItem.isEnabled = !isRecording
        menu.addItem(selectOutputDirectoryItem)

        menu.addItem(NSMenuItem(title: "保存先を開く", action: #selector(openOutputDirectory), keyEquivalent: "o"))

        let outputFormatMenuItem = NSMenuItem(title: "保存形式", action: nil, keyEquivalent: "")
        let outputFormatMenu = NSMenu()
        for outputFormat in AudioOutputFormat.allCases {
            let item = NSMenuItem(title: outputFormat.displayName, action: #selector(selectOutputFormat(_:)), keyEquivalent: "")
            item.representedObject = outputFormat.rawValue
            item.state = selectedOutputFormat == outputFormat ? .on : .off
            item.isEnabled = !isRecording
            outputFormatMenu.addItem(item)
        }
        outputFormatMenuItem.submenu = outputFormatMenu
        menu.addItem(outputFormatMenuItem)

        let mergeSegmentsItem = NSMenuItem(title: "停止後に分割ファイルを結合", action: #selector(toggleSegmentMergePreference), keyEquivalent: "")
        mergeSegmentsItem.state = mergeSegmentsAfterRecording ? .on : .off
        mergeSegmentsItem.isEnabled = !isRecording
        menu.addItem(mergeSegmentsItem)

        let hint = NSMenuItem(title: "ASR品質重視ならイヤホン推奨", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(NSMenuItem.separator())

        if !latestFiles.isEmpty {
            menu.addItem(NSMenuItem(title: "最後の保存ファイルを表示", action: #selector(revealLatestFile), keyEquivalent: "f"))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private var isFailed: Bool {
        if case .failed = recorderState {
            return true
        }
        return false
    }

    private var finishedAlertTitle: String {
        isFailed ? "途中まで保存しました" : "録音を保存しました"
    }

    private var isRecording: Bool {
        if case .diagnosing = recorderState {
            return true
        }
        if case .recording = recorderState {
            return true
        }
        if case .paused = recorderState {
            return true
        }
        if case .stopping = recorderState {
            return true
        }
        return false
    }

    private var isPaused: Bool {
        if case .paused = recorderState {
            return true
        }
        return false
    }

    private var canTogglePause: Bool {
        switch recorderState {
        case .recording, .paused:
            return true
        case .idle, .diagnosing, .stopping, .failed:
            return false
        }
    }

    private var outputDirectoryMenuTitle: String {
        "保存先: \(abbreviatedPath(for: selectedOutputDirectory))"
    }

    private var recordingTitleMenuTitle: String {
        guard let title = RecordingFilenameGenerator.sanitizedTitle(recordingTitle) else {
            return "録音タイトル: 未設定"
        }
        return "録音タイトル: \(title)"
    }

    private var statusText: String {
        switch recorderState {
        case .idle:
            return "待機中: \(selectedMode.displayName)"
        case .diagnosing(let mode, _):
            return "入力確認中: \(mode.displayName)"
        case .recording(let mode, let startedAt):
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            formatter.dateStyle = .none
            let elapsed = RecordingElapsedTimeFormatter.string(startedAt: startedAt)
            return "録音中: \(mode.displayName) / 開始 \(formatter.string(from: startedAt)) / 経過 \(elapsed)"
        case .paused(let mode, let startedAt, let pausedAt):
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            formatter.dateStyle = .none
            let elapsed = RecordingElapsedTimeFormatter.string(startedAt: startedAt, now: pausedAt)
            return "一時停止中: \(mode.displayName) / 開始 \(formatter.string(from: startedAt)) / 経過 \(elapsed)"
        case .stopping:
            return "録音停止中..."
        case .failed(let message):
            let firstLine = message.components(separatedBy: "\n").first ?? message
            return "エラー: \(firstLine)"
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            Task {
                await engine.stop()
            }
            return
        }

        let shouldClearFailure = isFailed
        let recordingSettings = recordingSettingsForCurrentSelection()

        Task {
            do {
                if shouldClearFailure {
                    engine.clearFailure()
                }
                try await ensurePermissions(for: selectedMode)
                try await engine.start(
                    mode: selectedMode,
                    microphoneDeviceID: selectedMicrophoneID,
                    sessionTitle: recordingTitle,
                    recordingSettings: recordingSettings
                )
            } catch {
                showRecorderStartError(error)
            }
        }
    }

    @objc private func togglePause() {
        switch recorderState {
        case .recording:
            Task {
                await engine.pause()
            }
        case .paused:
            Task {
                await engine.resume()
            }
        case .idle, .diagnosing, .stopping, .failed:
            break
        }
    }

    private func showRecorderStartError(_ error: Error) {
        if let recorderError = error as? RecorderError {
            showAlert(title: recorderError.alertTitle, message: recorderError.displayMessage)
            return
        }

        showAlert(title: "録音を開始できません", message: error.localizedDescription)
    }

    @objc private func clearRecorderError() {
        engine.clearFailure()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = RecordingMode(rawValue: rawValue) else {
            return
        }
        selectedMode = mode
        rebuildMenu()
    }

    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        selectedMicrophoneID = sender.representedObject as? String
        rebuildMenu()
    }

    @objc private func selectOutputFormat(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let outputFormat = AudioOutputFormat(rawValue: rawValue) else {
            return
        }
        selectedOutputFormat = outputFormat
        audioOutputFormatStore.saveOutputFormat(outputFormat)
        rebuildMenu()
    }

    @objc private func toggleSegmentMergePreference() {
        mergeSegmentsAfterRecording.toggle()
        segmentMergePreferenceStore.saveMergeSegmentsAfterRecording(mergeSegmentsAfterRecording)
        rebuildMenu()
    }

    @objc private func setRecordingTitle() {
        let input = NSTextField(string: recordingTitle)
        input.placeholderString = "例: 週次定例"
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = "録音タイトル"
        alert.informativeText = "次回開始する録音のファイル名に使います。"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = input

        if alert.runModal() == .alertFirstButtonReturn {
            recordingTitle = input.stringValue
            rebuildMenu()
        }
    }

    @objc private func clearRecordingTitle() {
        recordingTitle = ""
        rebuildMenu()
    }

    @objc private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "保存先を選択"
        panel.message = "録音ファイルを保存するフォルダを選択してください。"
        panel.prompt = "選択"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = selectedOutputDirectory

        guard panel.runModal() == .OK, let directory = panel.url?.standardizedFileURL else {
            return
        }

        guard outputDirectoryStore.isUsableDirectory(directory) else {
            showAlert(title: "保存先を変更できません", message: "選択したフォルダに書き込めません。\n\(directory.path)")
            return
        }

        selectedOutputDirectory = directory
        outputDirectoryStore.saveOutputDirectory(directory)
        rebuildMenu()
    }

    @objc private func openOutputDirectory() {
        NSWorkspace.shared.open(selectedOutputDirectory)
    }

    @objc private func revealLatestFile() {
        guard let latest = latestFiles.last else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([latest])
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func ensurePermissions(for mode: RecordingMode) async throws {
        switch PermissionService.microphoneStatus() {
        case .authorized:
            break
        case .notDetermined:
            let granted = await PermissionService.requestMicrophoneAccess()
            guard granted else {
                throw RecorderError.permissionDenied("マイク権限が許可されていません。")
            }
        case .denied, .restricted, .unknown:
            throw RecorderError.permissionDenied("システム設定でマイク権限を許可してください。")
        }

        guard mode.capturesSystemAudio else {
            return
        }

        if PermissionService.screenCaptureStatus() == .authorized {
            return
        }

        let granted = PermissionService.requestScreenCaptureAccess()
        guard granted || PermissionService.screenCaptureStatus() == .authorized else {
            throw RecorderError.permissionDenied("システム設定で画面収録権限を許可し、必要に応じてアプリを再起動してください。")
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
