import Foundation
import SwiftUI
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import UniformTypeIdentifiers

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
    /// Optional second camera (e.g. the second display's), chosen in the Sources list.
    @Published var secondCameraID: String? {
        didSet { UserDefaults.standard.set(secondCameraID, forKey: "secondCameraID") }
    }
    /// Which camera is live right now (the first or the second).
    @Published var usingSecondCamera = false
    /// When on, ⌃⌥S also changes camera: main screen → first camera, second screen → second camera.
    @Published var cameraFollowsScreen: Bool {
        didSet { UserDefaults.standard.set(cameraFollowsScreen, forKey: "cameraFollowsScreen") }
    }
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
    @Published var editing = false
    @Published var statusMessage = ""
    @Published var lastOutputFolder: URL?
    @Published var errorMessage: String?
    /// Name of the demo app being recorded instead of the slides, if any.
    @Published var demoAppName: String?
    /// True while the camera is recorded full screen (⌃⌥C), until toggled back.
    @Published var cameraFullScreenActive = false
    /// Windows open right now (kept current during a preview), and the ones
    /// ticked to switch between in the Monitor.
    @Published var openWindows: [SCWindow] = []
    @Published var pickedWindowIDs: Set<CGWindowID> = []
    /// The demo-type window being recorded right now, if any.
    @Published var capturedDemoWindowID: CGWindowID?
    /// Comma-separated title fragments of windows that are never recorded.
    @Published var neverRecordText: String {
        didSet {
            UserDefaults.standard.set(neverRecordText, forKey: "neverRecordTitles")
            SlideCapture.neverRecordTitles = Self.parseTitles(neverRecordText)
        }
    }
    static let defaultNeverRecord = "Speaker View, reveal.js - Notes"
    static func parseTitles(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    private var layoutBeforeCameraFullScreen: Layout?
    private let hotKeys = HotKeys()

    // MARK: Settings (persisted)

    @Published var whisperModel: String {
        didSet { UserDefaults.standard.set(whisperModel, forKey: "whisperModel") }
    }
    /// The deck's Quarto source (.qmd), chosen per launch. When set, the
    /// transcript and the deck's speaker notes are corrected from it.
    @Published var deckURL: URL?
    /// Name of the Ollama model that makes the corrections.
    @Published var correctionModel: String {
        didSet { UserDefaults.standard.set(correctionModel, forKey: "correctionModel") }
    }
    @Published var correctionEnabled: Bool {
        didSet { UserDefaults.standard.set(correctionEnabled, forKey: "correctionEnabled") }
    }
    /// Digital camera zoom (1…4×) and pan (-1…1), kept across launches.
    @Published var cameraZoom: Double {
        didSet { UserDefaults.standard.set(cameraZoom, forKey: "cameraZoom"); applyFraming() }
    }
    @Published var cameraPanX: Double {
        didSet { UserDefaults.standard.set(cameraPanX, forKey: "cameraPanX"); applyFraming() }
    }
    @Published var cameraPanY: Double {
        didSet { UserDefaults.standard.set(cameraPanY, forKey: "cameraPanY"); applyFraming() }
    }
    private func applyFraming() {
        pipeline.framing = CameraFraming(zoom: cameraZoom, panX: cameraPanX, panY: cameraPanY)
    }
    func resetZoom() {
        cameraZoom = 1; cameraPanX = 0; cameraPanY = 0
    }

    @Published var mirrorCamera: Bool {
        didSet {
            UserDefaults.standard.set(mirrorCamera, forKey: "mirrorCamera")
            pipeline.mirrorCamera = mirrorCamera
        applyFraming()
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
            pipeline.slides.demoBundleIDs = []
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
        correctionModel = defaults.string(forKey: "correctionModel") ?? ContentCorrector.defaultModel
        correctionEnabled = defaults.object(forKey: "correctionEnabled") as? Bool ?? true
        mirrorCamera = defaults.bool(forKey: "mirrorCamera")
        cameraZoom = max(1, min(4, defaults.object(forKey: "cameraZoom") as? Double ?? 1))
        cameraPanX = defaults.double(forKey: "cameraPanX")
        cameraPanY = defaults.double(forKey: "cameraPanY")
        let neverRecord = defaults.string(forKey: "neverRecordTitles") ?? Self.defaultNeverRecord
        neverRecordText = neverRecord
        SlideCapture.neverRecordTitles = Self.parseTitles(neverRecord)
        cameraFollowsScreen = defaults.object(forKey: "cameraFollowsScreen") as? Bool ?? true
        secondCameraID = defaults.string(forKey: "secondCameraID")
        countdownEnabled = defaults.object(forKey: "countdownEnabled") as? Bool ?? true
        showCursor = defaults.bool(forKey: "showCursor")
        SlideCapture.showsCursor = defaults.bool(forKey: "showCursor")
        autoLevelEnabled = defaults.object(forKey: "autoLevelEnabled") as? Bool ?? true
        voiceCleanupEnabled = defaults.object(forKey: "voiceCleanupEnabled") as? Bool ?? true
        demoApps = defaults.dictionary(forKey: "demoApps") as? [String: String] ?? [:]
        pipeline.slides.demoBundleIDs = []

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
        hotKeys.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .switchScreen: Task { await self.switchScreen() }
            case .cameraFullScreen: self.toggleCameraFullScreen()
            case .switchCamera: self.switchCamera()
            case .switchApp: Task { await self.switchApp() }
            }
        }
        hotKeys.register()
        pipeline.slides.onCapturedWindow = { [weak self] id, demo in
            DispatchQueue.main.async { self?.capturedDemoWindowID = demo ? id : nil }
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
            openWindows = windows
            displays = try await SlideCapture.availableDisplays()
        } catch {
            errorMessage = "Could not list windows — grant Screen Recording permission in System Settings ▸ Privacy & Security, then relaunch. (\(error.localizedDescription))"
        }
        startWindowRefresh()
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
        // The window list can be stale (windows opened, closed or moved since
        // launch): refresh it so the chosen window is a live one.
        let wasWindow = selectedSourceID?.hasPrefix("window:") == true
        if let fresh = try? await SlideCapture.availableWindows() { windows = fresh; openWindows = fresh }
        if let fresh = try? await SlideCapture.availableDisplays(), !fresh.isEmpty { displays = fresh }
        if wasWindow, selectedSlideSource == nil {
            errorMessage = "The slides window you chose is no longer open (or is minimized). Pick it again in the Slides list."
            selectedSourceID = windows.first.map { Self.sourceID($0) } ?? displays.first.map { Self.sourceID($0) }
            return
        }
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
            await pipeline.stopAll()
            let ns = error as NSError
            errorMessage = "Could not start preview: \(error.localizedDescription) [\(ns.domain) \(ns.code)]. If the slides source is a window, make sure it is open and not minimized, or choose Entire screen. If this keeps happening, quit and reopen Lecture Reflector."
        }
    }

    // MARK: Screen switching and camera full screen (global hotkeys)

    /// Displays with the main screen (menu bar) first, then the others.
    private var orderedDisplays: [SCDisplay] {
        displays.filter { $0.displayID == CGMainDisplayID() } + displays.filter { $0.displayID != CGMainDisplayID() }
    }

    /// ⌃⌥S: record the other screen. Cycles through the displays, so with two
    /// screens it flips between them. From a window source it goes to the
    /// main screen first. The speaker notes stay on whichever screen you are
    /// not recording.
    func switchScreen() async {
        guard phase == .previewing || phase == .recording || phase == .countdown else { return }
        await refreshDisplays()
        let list = orderedDisplays
        guard list.count > 0 else { return }
        let currentIndex = list.firstIndex { Self.sourceID($0) == selectedSourceID }
        let next = list[currentIndex.map { ($0 + 1) % list.count } ?? 0]
        do {
            try await pipeline.slides.switchToDisplay(next)
            selectedSourceID = Self.sourceID(next)
            if cameraFollowsScreen, secondCameraID != nil {
                setSecondCamera(next.displayID != CGMainDisplayID())
            }
            // The camera was full screen: switching screens shows the screen again.
            if cameraFullScreenActive { toggleCameraFullScreen() }
            pipeline.markEvent("Switched to \(next.displayID == CGMainDisplayID() ? "main" : "second") screen")
        } catch {
            errorMessage = "Could not switch screens: \(error.localizedDescription)"
        }
    }

    // MARK: What to record (slides, apps, picked windows)

    /// Something the Monitor can switch the recording to.
    enum RecordTarget: Identifiable, Equatable {
        case slides
        case app(bundleID: String, name: String)
        case window(id: CGWindowID, label: String)

        var id: String {
            switch self {
            case .slides: return "slides"
            case .app(let bundleID, _): return "app:\(bundleID)"
            case .window(let id, _): return "window:\(id)"
            }
        }
        var label: String {
            switch self {
            case .slides: return "Slides"
            case .app(_, let name): return "\(name) (front window)"
            case .window(_, let label): return label
            }
        }
    }

    static func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "App"
        let title = (window.title ?? "").trimmingCharacters(in: .whitespaces)
        let text = title.isEmpty ? app : "\(app) — \(title)"
        return text.count > 60 ? String(text.prefix(59)) + "…" : text
    }

    /// Open windows other than the slides window, for picking extras.
    var pickableWindows: [SCWindow] {
        openWindows
            .filter { Self.sourceID($0) != selectedSourceID }
            .sorted { Self.windowLabel($0).localizedCaseInsensitiveCompare(Self.windowLabel($1)) == .orderedAscending }
    }

    func setPicked(_ window: SCWindow, picked: Bool) {
        if picked { pickedWindowIDs.insert(window.windowID) } else { pickedWindowIDs.remove(window.windowID) }
    }

    /// The slides, each ticked demo app, then each picked window that is still open.
    var targets: [RecordTarget] {
        let windows = pickableWindows
            .filter { pickedWindowIDs.contains($0.windowID) }
            .map { RecordTarget.window(id: $0.windowID, label: Self.windowLabel($0)) }
        return [.slides] + windows
    }

    var activeTarget: RecordTarget {
        let list = targets
        if let id = capturedDemoWindowID, let match = list.first(where: { $0.id == "window:\(id)" }) {
            return match
        }
        if let name = demoAppName,
           let match = list.first(where: { if case .app(_, let n) = $0 { return n == name } else { return false } }) {
            return match
        }
        return demoAppName == nil ? .slides : (list.first ?? .slides)
    }

    /// Records the chosen target. Window sources only.
    @discardableResult
    func select(_ target: RecordTarget) async -> Bool {
        guard phase == .previewing || phase == .recording || phase == .countdown else { return false }
        guard slidesSourceIsWindow else {
            errorMessage = "Switching windows needs a window as the slides source, not an entire screen."
            return false
        }
        let ok: Bool
        switch target {
        case .slides: ok = await pipeline.slides.show(bundleID: nil)
        case .app(let bundleID, _): ok = await pipeline.slides.show(bundleID: bundleID)
        case .window(let id, _): ok = await pipeline.slides.show(windowID: id)
        }
        if !ok { statusMessage = "Couldn't show \(target.label) — is it open and not minimized?" }
        return ok
    }

    /// ⌃⌥A: the next target in the list (slides → apps → picked windows → slides).
    func switchApp() async {
        let list = targets
        guard list.count > 1 else {
            errorMessage = "Tick apps under Demo apps, or pick windows under Windows to switch between, first."
            return
        }
        let current = list.firstIndex(of: activeTarget) ?? 0
        for step in 1...list.count {
            if await select(list[(current + step) % list.count]) { return }
        }
    }

    private var windowRefreshTask: Task<Void, Never>?

    /// Keeps the list of open windows current.
    func startWindowRefresh() {
        guard windowRefreshTask == nil else { return }
        windowRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if let fresh = try? await SlideCapture.availableWindows() {
                    self.openWindows = fresh
                    // Keep the Slides list current while idle, so it never offers a window that closed.
                    if self.phase == .idle {
                        self.windows = fresh
                        if let displays = try? await SlideCapture.availableDisplays(), !displays.isEmpty {
                            self.displays = displays
                        }
                    }
                }
            }
        }
    }

    /// ⌃⌥V: switch between the first and second camera.
    func switchCamera() {
        guard phase == .previewing || phase == .recording || phase == .countdown else { return }
        guard secondCameraID != nil else {
            errorMessage = "Choose a second camera in Sources first."
            return
        }
        setSecondCamera(!usingSecondCamera)
    }

    private func setSecondCamera(_ useSecond: Bool) {
        guard useSecond != usingSecondCamera else { return }
        let id = useSecond ? secondCameraID : selectedCameraID
        guard let device = cameras.first(where: { $0.uniqueID == id }) else {
            errorMessage = "That camera isn't connected."
            return
        }
        do {
            try pipeline.camera.switchCamera(to: device)
            usingSecondCamera = useSecond
            pipeline.markEvent("Camera: \(device.localizedName)")
        } catch {
            errorMessage = "Could not switch camera: \(error.localizedDescription)"
        }
    }

    /// ⌃⌥C: record only the camera, full screen, until pressed again.
    func toggleCameraFullScreen() {
        guard phase == .previewing || phase == .recording || phase == .countdown else { return }
        if cameraFullScreenActive {
            layout = layoutBeforeCameraFullScreen ?? .rectanglePiP
            layoutBeforeCameraFullScreen = nil
            cameraFullScreenActive = false
            pipeline.markEvent("Back from camera full screen")
        } else {
            layoutBeforeCameraFullScreen = layout
            layout = .cameraOnly
            cameraFullScreenActive = true
            pipeline.markEvent("Camera full screen")
        }
    }

    private func refreshDisplays() async {
        if let fresh = try? await SlideCapture.availableDisplays(), !fresh.isEmpty {
            displays = fresh
        }
    }

    func stopPreview() async {
        if cameraFullScreenActive { toggleCameraFullScreen() }
        usingSecondCamera = false
        capturedDemoWindowID = nil
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
            var segments = try await transcriber.transcribe(mediaURL: movieURL, model: whisperModel) { [weak self] message in
                Task { @MainActor in
                    self?.statusMessage = message
                }
            }
            var note = ""
            if let deckURL, correctionEnabled {
                // Whisper's own output is kept; the corrected files replace lecture.txt and lecture.srt.
                try? Transcriber.writeRawTranscript(segments, to: folder)
                do {
                    let outcome = try await ContentCorrector.apply(deckURL: deckURL, model: correctionModel, to: segments, folder: folder) { [weak self] message in
                        Task { @MainActor in self?.statusMessage = message }
                    }
                    segments = outcome.segments
                    note = " " + outcome.summary
                } catch {
                    errorMessage = "The transcript was saved as Whisper heard it, without corrections from the deck. \(error.localizedDescription)"
                }
            }
            try Transcriber.writeTranscript(segments, to: folder)
            statusMessage = "Saved video, transcript, and chapters." + note
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

    // MARK: Correcting from the deck

    func chooseDeck() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ["qmd", "md", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.prompt = "Choose Deck"
        panel.message = "Choose the Quarto source (.qmd) of the deck you are lecturing from"
        if panel.runModal() == .OK, let url = panel.url {
            deckURL = url
        }
    }

    /// Corrects an existing recording's transcript and the deck's speaker
    /// notes from the chosen deck. Starts from Whisper's original output
    /// (lecture-words-raw.json) when the recording has it.
    func correctRecordingFromDeck() async {
        if deckURL == nil { chooseDeck() }
        guard let deckURL else { return }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = lastOutputFolder ?? outputFolder
        panel.prompt = "Choose Recording"
        panel.message = "Choose a recording folder (the one with lecture.mp4 and lecture-words.json)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let hasRaw = FileManager.default.fileExists(atPath: folder.appendingPathComponent(WordTranscript.rawFileName).path)
        let source: WordTranscript
        do {
            source = try WordTranscript.load(from: folder, fileName: hasRaw ? WordTranscript.rawFileName : WordTranscript.fileName)
        } catch {
            errorMessage = "“\(folder.lastPathComponent)” has no word-timed transcript yet. Use “Cut Video from Edited Transcript…” and choose its folder to transcribe it first."
            return
        }
        let segments = source.segments.map {
            TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, words: $0.words)
        }

        transcribing = true
        statusMessage = "Correcting from the deck…"
        do {
            if !hasRaw { try Transcriber.writeRawTranscript(segments, to: folder) }
            let outcome = try await ContentCorrector.apply(deckURL: deckURL, model: correctionModel, to: segments, folder: folder) { [weak self] message in
                Task { @MainActor in self?.statusMessage = message }
            }
            try Transcriber.writeTranscript(outcome.segments, to: folder)
            lastOutputFolder = folder
            statusMessage = outcome.summary
        } catch {
            errorMessage = "Could not correct the recording: \(error.localizedDescription)"
            statusMessage = ""
        }
        transcribing = false
    }

    // MARK: Editing by transcript

    func openEditFileForLastRecording() {
        guard let folder = lastOutputFolder else { return }
        let url = folder.appendingPathComponent(TranscriptEdit.editFileName)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            errorMessage = "This recording has no \(TranscriptEdit.editFileName) yet. Use “Cut Video from Edited Transcript…” and choose its folder to transcribe it with word timing."
        }
    }

    /// Asks for a recording folder and writes lecture-edited.mp4 from its
    /// edited lecture-edit.txt. A recording made before word timing existed
    /// is transcribed again first.
    func cutFromEditedTranscript() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = lastOutputFolder ?? outputFolder
        panel.prompt = "Choose Recording"
        panel.message = "Choose a recording folder (the one with lecture.mp4 and lecture-edit.txt)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("lecture.mp4").path) else {
            errorMessage = "“\(folder.lastPathComponent)” has no lecture.mp4. Choose the folder of one recording."
            return
        }

        if !EditExporter.hasWordTimes(in: folder) {
            let alert = NSAlert()
            alert.messageText = "This recording has no word timing yet"
            alert.informativeText = "Lecture Reflector will transcribe it again with word timing, which takes a few minutes. Then edit lecture-edit.txt and choose “Cut Video from Edited Transcript…” again. Its lecture.txt and lecture.srt are replaced with the new transcription."
            alert.addButton(withTitle: "Transcribe Again")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await transcribe(movieURL: folder.appendingPathComponent("lecture.mp4"), folder: folder)
            let editURL = folder.appendingPathComponent(TranscriptEdit.editFileName)
            if FileManager.default.fileExists(atPath: editURL.path) {
                lastOutputFolder = folder
                statusMessage = "Transcribed with word timing. Edit lecture-edit.txt, then cut the video."
                NSWorkspace.shared.open(editURL)
            }
            return
        }

        editing = true
        statusMessage = "Reading the edited transcript…"
        do {
            let result = try await EditExporter.cut(folder: folder) { [weak self] message in
                Task { @MainActor in self?.statusMessage = message }
            }
            statusMessage = result.summary
            NSWorkspace.shared.activateFileViewerSelecting([result.videoURL])
        } catch {
            errorMessage = "Could not cut the video: \(error.localizedDescription)"
            statusMessage = ""
        }
        editing = false
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
