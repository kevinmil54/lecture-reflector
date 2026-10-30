import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// An app offered in the Demo apps list.
struct DemoAppChoice: Identifiable, Hashable {
    let id: String      // bundle ID
    let name: String
}

/// UI-facing state machine that orchestrates the pipeline and transcription.
@MainActor
final class RecordingSession: ObservableObject {
    enum Phase: Equatable {
        case idle          // nothing running; pick sources
        case previewing    // live preview, ready to record
        case countdown
        case recording
        case finishing     // finalizing the MP4
    }

    @Published var phase: Phase = .idle
    @Published var windows: [SCWindow] = []
    @Published var displays: [SCDisplay] = []
    /// What the slide capture is currently showing (it can switch windows
    /// on its own when a deck goes full screen).
    @Published var slideSourceStatus = ""
    @Published var cameras: [AVCaptureDevice] = []
    @Published var microphones: [AVCaptureDevice] = []
    /// "window:<id>" or "display:<id>".
    @Published var selectedSourceID: String? {
        didSet { loadCropForSelectedSource() }
    }
    /// Edges trimmed off the slides (points), remembered per app.
    @Published var slideCrop = SlideCrop.none {
        didSet { pipeline.slides.crop = slideCrop }
    }
    @Published var selectedCameraID: String?
    @Published var selectedMicID: String?
    @Published var layout: Layout = .rectanglePiP {
        didSet { pipeline.layout = layout }
    }
    @Published var previewImage: CGImage?
    @Published var lectureTitle: String = "Lecture"
    @Published var outputFolder: URL
    @Published var recordingStartedAt: Date?
    @Published var isPaused = false
    @Published var pausedElapsed: TimeInterval = 0
    @Published var countdownValue: Int?
    @Published var audioLevel: Float = -160
    @Published var audioQuality = AudioQuality()
    @Published var transcribing = false
    @Published var statusMessage = ""
    @Published var lastOutputFolder: URL?
    @Published var errorMessage: String?
    /// Name of the demo app being recorded instead of the slides, if any.
    @Published var demoAppName: String?

    // MARK: Settings (persisted)

    @Published var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }
    @Published var mirrorCamera: Bool {
        didSet {
            UserDefaults.standard.set(mirrorCamera, forKey: "mirrorCamera")
            pipeline.mirrorCamera = mirrorCamera
        }
    }
    @Published var countdownEnabled: Bool {
        didSet { UserDefaults.standard.set(countdownEnabled, forKey: "countdownEnabled") }
    }
    /// Draw the mouse pointer into the captured slides.
    @Published var showCursor: Bool {
        didSet {
            UserDefaults.standard.set(showCursor, forKey: "showCursor")
            SlideCapture.showsCursor = showCursor
            Task { await pipeline.slides.applyConfiguration() }
        }
    }
    /// Bring each finished recording's audio to -16 LUFS.
    @Published var autoLevelEnabled: Bool {
        didSet { UserDefaults.standard.set(autoLevelEnabled, forKey: "autoLevelEnabled") }
    }
    /// High-pass, presence shelf and gentle compression before the level
    /// correction. Only applies when `autoLevelEnabled` is on.
    @Published var voiceCleanupEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceCleanupEnabled, forKey: "voiceCleanupEnabled") }
    }
    /// Apps whose windows replace the slides while they are in front
    /// (bundle ID → app name), remembered between launches.
    @Published var demoApps: [String: String] {
        didSet {
            UserDefaults.standard.set(demoApps, forKey: "demoApps")
            pipeline.slides.demoBundleIDs = Set(demoApps.keys)
        }
    }
    /// Lecturer position/size per floating layout, remembered between launches.
    @Published private(set) var placements: [Layout: LecturerPlacement] = [:]
    /// Slide area position/size; defaults to the full frame.
    @Published private(set) var slidePlacement = LecturerPlacement.fullFrame

    static let whisperModels = ["base", "small", "medium", "large-v3"]

    /// Live figures for the monitor panel; read on a timer rather than published.
    var recordedSeconds: TimeInterval? { pipeline.recorder.elapsedSeconds }
    var slideChanges: [TimeInterval] { pipeline.chapters }

    private let pipeline = Pipeline()
    private let transcriber = Transcriber()
    private var sessionFolder: URL?
    private var activityToken: NSObjectProtocol?
    private var pauseBegan: Date?

    init() {
        let defaults = UserDefaults.standard
        outputFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        whisperModel = defaults.string(forKey: "whisperModel") ?? "base"
        mirrorCamera = defaults.bool(forKey: "mirrorCamera")
        countdownEnabled = defaults.object(forKey: "countdownEnabled") as? Bool ?? true
        showCursor = defaults.bool(forKey: "showCursor")
        SlideCapture.showsCursor = defaults.bool(forKey: "showCursor")
        autoLevelEnabled = defaults.object(forKey: "autoLevelEnabled") as? Bool ?? true
        voiceCleanupEnabled = defaults.object(forKey: "voiceCleanupEnabled") as? Bool ?? true
        demoApps = defaults.dictionary(forKey: "demoApps") as? [String: String] ?? [:]
        pipeline.slides.demoBundleIDs = Set(demoApps.keys)

        pipeline.mirrorCamera = mirrorCamera
        if let data = defaults.data(forKey: "lecturerPlacements"),
           let stored = try? JSONDecoder().decode([String: LecturerPlacement].self, from: data) {
            for (key, value) in stored {
                if let layout = Layout(rawValue: key) {
                    placements[layout] = value
                    pipeline.setPlacement(value, for: layout)
                }
            }
        }
        if let data = defaults.data(forKey: "slidePlacement"),
           let stored = try? JSONDecoder().decode(LecturerPlacement.self, from: data) {
            slidePlacement = stored
            pipeline.setSlidePlacement(stored)
        }
        pipeline.slides.onSourceChanged = { [weak self] description in
            DispatchQueue.main.async {
                self?.slideSourceStatus = description
            }
        }
        pipeline.slides.onDemoChanged = { [weak self, pipeline] name in
            pipeline.markEvent(name.map { "Demo: \($0)" } ?? "Back to slides")
            DispatchQueue.main.async {
                self?.demoAppName = name
            }
        }
        pipeline.onPreview = { [weak self] cgImage in
            DispatchQueue.main.async {
                self?.previewImage = cgImage
            }
        }
        pipeline.onAudioLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.audioLevel = level
            }
        }
        pipeline.onAudioQuality = { [weak self] quality in
            DispatchQueue.main.async {
                self?.audioQuality = quality
            }
        }
    }

    // MARK: Lecturer placement

    func placement(for layout: Layout) -> LecturerPlacement {
        placements[layout] ?? layout.defaultPlacement
    }

    func setPlacement(_ placement: LecturerPlacement, for layout: Layout, canvas: CGSize? = nil) {
        let clamped = placement.clamped(canvas: canvas ?? layout.canvasSize, aspect: layout.lecturerAspect)
        placements[layout] = clamped
        pipeline.setPlacement(clamped, for: layout)
    }

    /// Persist once a drag ends (not on every mouse move).
    func savePlacements() {
        let stored = Dictionary(uniqueKeysWithValues: placements.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: "lecturerPlacements")
        }
    }

    func resetPlacement(for layout: Layout) {
        setPlacement(layout.defaultPlacement, for: layout)
        savePlacements()
    }

    func setSlidePlacement(_ placement: LecturerPlacement, canvas: CGSize) {
        let clamped = placement.clamped(canvas: canvas, aspect: canvas.width / canvas.height, maxWidth: 1)
        slidePlacement = clamped
        pipeline.setSlidePlacement(clamped)
    }

    func saveSlidePlacement() {
        if let data = try? JSONEncoder().encode(slidePlacement) {
            UserDefaults.standard.set(data, forKey: "slidePlacement")
        }
    }

    func resetSlidePlacement() {
        slidePlacement = .fullFrame
        pipeline.setSlidePlacement(.fullFrame)
        saveSlidePlacement()
    }

    // MARK: Slide crop

    /// Crops are remembered per app ("com.apple.Safari") or for whole screens.
    private var cropKey: String? {
        if let window = windows.first(where: { Self.sourceID($0) == selectedSourceID }) {
            return window.owningApplication?.bundleIdentifier
        }
        if displays.contains(where: { Self.sourceID($0) == selectedSourceID }) {
            return "display"
        }
        return nil
    }

    private var storedCrops: [String: SlideCrop] {
        guard let data = UserDefaults.standard.data(forKey: "slideCrops"),
              let crops = try? JSONDecoder().decode([String: SlideCrop].self, from: data)
        else { return [:] }
        return crops
    }

    private func loadCropForSelectedSource() {
        let crop = cropKey.flatMap { storedCrops[$0] } ?? .none
        if crop != slideCrop {
            slideCrop = crop
        }
    }

    func saveSlideCrop() {
        guard let key = cropKey else { return }
        var crops = storedCrops
        crops[key] = slideCrop
        if let data = try? JSONEncoder().encode(crops) {
            UserDefaults.standard.set(data, forKey: "slideCrops")
        }
    }

    // MARK: Demo apps

    /// Apps with open windows (plus any already chosen), minus the slides
    /// app and Lecture Reflector, sorted by name.
    var demoAppChoices: [DemoAppChoice] {
        var choices = demoApps
        for window in windows {
            guard let app = window.owningApplication, !app.bundleIdentifier.isEmpty else { continue }
            choices[app.bundleIdentifier] = app.applicationName
        }
        if let slides = slidesBundleID {
            choices[slides] = nil
        }
        return choices
            .map { DemoAppChoice(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func setDemoApp(_ choice: DemoAppChoice, enabled: Bool) {
        demoApps[choice.id] = enabled ? choice.name : nil
    }

    /// Demo switching needs a window source; it does nothing with Entire screen.
    var slidesSourceIsWindow: Bool {
        windows.contains { Self.sourceID($0) == selectedSourceID }
    }

    private var slidesBundleID: String? {
        windows.first { Self.sourceID($0) == selectedSourceID }?.owningApplication?.bundleIdentifier
    }

    // MARK: Sources

    static func sourceID(_ window: SCWindow) -> String { "window:\(window.windowID)" }
    static func sourceID(_ display: SCDisplay) -> String { "display:\(display.displayID)" }

    private var selectedSlideSource: SlideCapture.Source? {
        if let window = windows.first(where: { Self.sourceID($0) == selectedSourceID }) {
            return .window(window)
        }
        if let display = displays.first(where: { Self.sourceID($0) == selectedSourceID }) {
            return .display(display)
        }
        return nil
    }

    func refreshSources() async {
        do {
            windows = try await SlideCapture.availableWindows()
            displays = try await SlideCapture.availableDisplays()
        } catch {
            errorMessage = "Could not list windows — grant Screen Recording permission in System Settings ▸ Privacy & Security, then relaunch. (\(error.localizedDescription))"
        }
        cameras = CameraCapture.videoDevices
        microphones = CameraCapture.audioDevices
        if selectedSlideSource == nil {
            selectedSourceID = windows.first.map { Self.sourceID($0) } ?? displays.first.map { Self.sourceID($0) }
        } else {
            loadCropForSelectedSource()
        }
        if selectedCameraID == nil {
            selectedCameraID = cameras.first?.uniqueID
        }
        if selectedMicID == nil {
            selectedMicID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? microphones.first?.uniqueID
        }
    }

    func startPreview() async {
        guard let slideSource = selectedSlideSource else {
            errorMessage = "Choose the window showing your slides first."
            return
        }
        guard let cameraDevice = cameras.first(where: { $0.uniqueID == selectedCameraID }) else {
            errorMessage = "Choose a camera first."
            return
        }
        let microphone = microphones.first(where: { $0.uniqueID == selectedMicID })

        let cameraOK = await AVCaptureDevice.requestAccess(for: .video)
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard cameraOK, micOK else {
            errorMessage = "LectureReflector needs camera and microphone access — enable both in System Settings ▸ Privacy & Security."
            return
        }

        do {
            pipeline.slides.crop = slideCrop
            try await pipeline.startPreview(slideSource: slideSource, cameraDevice: cameraDevice, microphone: microphone)
            phase = .previewing
        } catch {
            errorMessage = "Could not start preview: \(error.localizedDescription)"
        }
    }

    func stopPreview() async {
        await pipeline.stopAll()
        previewImage = nil
        slideSourceStatus = ""
        demoAppName = nil
        audioLevel = -160
        audioQuality = AudioQuality()
        phase = .idle
    }

    func startRecording() async {
        guard phase == .previewing else { return }

        if countdownEnabled {
            phase = .countdown
            for value in stride(from: 3, through: 1, by: -1) {
                countdownValue = value
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                // Bail out if the preview was stopped mid-countdown.
                guard phase == .countdown else {
                    countdownValue = nil
                    return
                }
            }
            countdownValue = nil
        }

        let stamp = Self.folderDateFormatter.string(from: Date())
        let title = lectureTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = outputFolder.appendingPathComponent(
            "LectureReflector \(title.isEmpty ? "Lecture" : title) \(stamp)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try pipeline.startRecording(to: folder.appendingPathComponent("lecture.mov"))
            sessionFolder = folder
            recordingStartedAt = Date()
            isPaused = false
            phase = .recording
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "Recording lecture"
            )
        } catch {
            phase = .previewing
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func togglePause() {
        guard phase == .recording else { return }
        if isPaused {
            if let began = pauseBegan {
                recordingStartedAt = recordingStartedAt?.addingTimeInterval(Date().timeIntervalSince(began))
                pauseBegan = nil
            }
            pipeline.recorder.resume()
            isPaused = false
        } else {
            pipeline.recorder.pause()
            pauseBegan = Date()
            pausedElapsed = pipeline.recorder.elapsedSeconds ?? 0
            isPaused = true
        }
    }

    func stopRecording() async {
        guard phase == .recording, let folder = sessionFolder else { return }
        if isPaused {
            togglePause()
        }
        phase = .finishing
        recordingStartedAt = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }

        let chapters = pipeline.chapters
        let events = pipeline.events
        do {
            statusMessage = "Finalizing video…"
            let movURL = try await pipeline.stopRecording()
            let audioCheck = pipeline.audioMonitor.endSummary()
            var micLine = "Microphone: unknown"
            if let mic = microphones.first(where: { $0.uniqueID == selectedMicID }) {
                micLine = "Microphone: \(mic.localizedName)"
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(mic.activeFormat.formatDescription)?.pointee {
                    micLine += String(format: " (native %.0f Hz, %d ch, %d-bit)", asbd.mSampleRate, asbd.mChannelsPerFrame, asbd.mBitsPerChannel)
                }
            }
            let mp4URL = folder.appendingPathComponent("lecture.mp4")
            try await Recorder.remuxToMP4(from: movURL, to: mp4URL)
            try? FileManager.default.removeItem(at: movURL)
            var levelLine = "Level correction: off"
            if autoLevelEnabled {
                statusMessage = voiceCleanupEnabled ? "Cleaning up audio…" : "Adjusting audio level…"
                do {
                    levelLine = try await AudioLeveler.normalize(fileAt: mp4URL, cleanup: voiceCleanupEnabled)
                } catch {
                    levelLine = "Level correction failed, original audio kept: \(error.localizedDescription)"
                }
            }
            try? (micLine + "\n" + audioCheck.text + levelLine + "\n")
                .write(to: folder.appendingPathComponent("audio-check.txt"), atomically: true, encoding: .utf8)
            writeChapters(chapters, events: events, to: folder)
            lastOutputFolder = folder
            statusMessage = ""
            phase = .previewing
            if let warning = audioCheck.warning {
                errorMessage = "Audio problem in this recording. \(warning) Details are in audio-check.txt."
            }
            await transcribe(movieURL: mp4URL, folder: folder)
        } catch {
            errorMessage = "Could not finalize the recording: \(error.localizedDescription)"
            statusMessage = ""
            phase = .previewing
        }
        sessionFolder = nil
    }

    private func transcribe(movieURL: URL, folder: URL) async {
        transcribing = true
        statusMessage = "Starting transcription…"
        do {
            let segments = try await transcriber.transcribe(mediaURL: movieURL, model: whisperModel) { [weak self] message in
                Task { @MainActor in
                    self?.statusMessage = message
                }
            }
            try Transcriber.writeTranscript(segments, to: folder)
            statusMessage = "Saved video, transcript, and chapters."
        } catch {
            // The video is already safe on disk even if transcription fails.
            errorMessage = "The video was saved, but transcription failed: \(error.localizedDescription)"
            statusMessage = ""
        }
        transcribing = false
    }

    private func writeChapters(_ chapters: [TimeInterval], events: [(TimeInterval, String)], to folder: URL) {
        var entries = chapters.enumerated().map { ($0.element, "Slide change \($0.offset + 1)") }
        entries += events
        entries.sort { $0.0 < $1.0 }
        var lines = ["00:00:00 — Start"]
        for (time, label) in entries {
            lines.append("\(Self.hms(time)) — \(label)")
        }
        try? lines.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("chapters.txt"), atomically: true, encoding: .utf8)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where LectureReflector saves lecture recordings"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
        }
    }

    func revealLastOutput() {
        guard let folder = lastOutputFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private static func hms(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let minutes = (Int(time) / 60) % 60
        let hours = Int(time) / 3600
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private static let folderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter
    }()
}
