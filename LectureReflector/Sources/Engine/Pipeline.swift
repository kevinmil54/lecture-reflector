import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// Owns the capture sources, compositor, and recorder, and drives the whole
/// pipeline with a 30 fps timer. Timer-driven (rather than frame-driven)
/// because slides sit unchanged for minutes and ScreenCaptureKit only delivers
/// frames on change — output cadence must not depend on slide activity.
final class Pipeline {
    let slides = SlideCapture()
    let camera = CameraCapture()
    let compositor = Compositor()
    let recorder = Recorder()
    let audioMonitor = AudioMonitor()

    private let renderQueue = DispatchQueue(label: "lecture_reflector.render", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var tick = 0

    private let lock = NSLock()
    private var _layout: Layout = .rectanglePiP
    private var _mirrorCamera = false
    private var _frozenCanvasSize: CGSize?
    private var _chapters: [TimeInterval] = []
    /// Labeled moments (switches to and from demo apps), seconds into the recording.
    private var _events: [(TimeInterval, String)] = []
    private var _placements: [Layout: LecturerPlacement] = [:]
    private var _slidePlacement = LecturerPlacement.fullFrame

    // Slide-change (chapter) detection state, touched only on renderQueue.
    private var chapterReference: CVPixelBuffer?
    private var lastChapterAt: TimeInterval = 0

    /// Live-switchable while recording.
    var layout: Layout {
        get { lock.withLock { _layout } }
        set { lock.withLock { _layout = newValue } }
    }

    var mirrorCamera: Bool {
        get { lock.withLock { _mirrorCamera } }
        set { lock.withLock { _mirrorCamera = newValue } }
    }

    /// Where the lecturer sits for each floating layout. Live-adjustable while recording.
    func setPlacement(_ placement: LecturerPlacement, for layout: Layout) {
        lock.withLock { _placements[layout] = placement }
    }

    /// Where the slides sit in the frame (shared by the floating layouts).
    func setSlidePlacement(_ placement: LecturerPlacement) {
        lock.withLock { _slidePlacement = placement }
    }

    /// Called at ~15 fps with the composited preview frame.
    var onPreview: ((CGImage) -> Void)?
    /// Called on the audio queue with the mic level in dBFS.
    var onAudioLevel: ((Float) -> Void)?
    /// Called on the audio queue (~4 Hz) with the audio check result.
    var onAudioQuality: ((AudioQuality) -> Void)?

    func startPreview(slideSource: SlideCapture.Source, cameraDevice: AVCaptureDevice, microphone: AVCaptureDevice?) async throws {
        try await slides.start(source: slideSource)
        try camera.start(camera: cameraDevice, microphone: microphone)
        camera.onAudioSampleBuffer = { [recorder, audioMonitor] sampleBuffer in
            recorder.appendAudio(sampleBuffer)
            audioMonitor.analyze(sampleBuffer, recording: recorder.isRecording && !recorder.isPaused)
        }
        audioMonitor.onQuality = { [weak self] quality in
            self?.onAudioQuality?(quality)
        }
        camera.onAudioLevel = { [weak self] level in
            self?.onAudioLevel?(level)
        }
        startTimer()
    }

    /// Freezes the canvas at the current layout's size (an MP4 video track
    /// cannot change dimensions mid-file) and starts writing.
    func startRecording(to url: URL) throws {
        let size = layout.canvasSize
        lock.withLock {
            _frozenCanvasSize = size
            _chapters = []
            _events = []
        }
        renderQueue.async { [weak self] in
            self?.chapterReference = nil
            self?.lastChapterAt = 0
        }
        audioMonitor.beginSummary()
        try recorder.start(
            outputURL: url,
            size: size,
            audioFormatHint: camera.latestAudioFormat
        )
    }

    func stopRecording() async throws -> URL {
        defer {
            lock.withLock { _frozenCanvasSize = nil }
        }
        return try await recorder.finish()
    }

    /// Chapter marks (seconds into the recording) detected so far.
    var chapters: [TimeInterval] {
        lock.withLock { _chapters }
    }

    /// Labeled events (e.g. "Demo: Obsidian") recorded so far.
    var events: [(TimeInterval, String)] {
        lock.withLock { _events }
    }

    /// Notes a labeled moment in the chapters file, if recording.
    func markEvent(_ label: String) {
        guard recorder.isRecording, let elapsed = recorder.elapsedSeconds else { return }
        lock.withLock { _events.append((elapsed, label)) }
    }

    func stopAll() async {
        timer?.cancel()
        timer = nil
        await slides.stop()
        camera.stop()
    }

    private func startTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.renderTick()
        }
        timer.resume()
        self.timer = timer
    }

    private func renderTick() {
        let (layout, mirror, frozenSize, savedPlacement, slidePlacement) = lock.withLock {
            (_layout, _mirrorCamera, _frozenCanvasSize, _placements[_layout], _slidePlacement)
        }
        let canvasSize = frozenSize ?? layout.canvasSize

        guard let (buffer, image) = compositor.composite(
            slide: slides.latestPixelBuffer,
            camera: camera.latestPixelBuffer,
            layout: layout,
            canvasSize: canvasSize,
            mirrorCamera: mirror,
            placement: savedPlacement ?? layout.defaultPlacement,
            slidePlacement: slidePlacement
        ) else { return }

        if recorder.isRecording {
            recorder.appendVideo(buffer, at: CMClockGetTime(CMClockGetHostTimeClock()))
        }

        tick += 1
        if tick % 15 == 0 {
            detectSlideChange()
        }
        if tick % 2 == 0, let onPreview, let cgImage = compositor.makeCGImage(image) {
            onPreview(cgImage)
        }
    }

    /// Twice a second while recording, compare the current slide frame with
    /// the one from the previous check; a large jump marks a chapter.
    private func detectSlideChange() {
        guard recorder.isRecording, !recorder.isPaused,
              let current = slides.latestPixelBuffer,
              let elapsed = recorder.elapsedSeconds,
              // A demo app changes constantly (typing, scrolling); its
              // switches are marked as events instead of slide changes.
              !slides.isDemoActive else {
            chapterReference = nil
            return
        }
        defer { chapterReference = current }
        guard let reference = chapterReference, reference !== current else { return }
        let score = compositor.slideChangeScore(current: current, previous: reference)
        if score > 0.015, elapsed - lastChapterAt > 2 {
            lastChapterAt = elapsed
            lock.withLock { _chapters.append(elapsed) }
        }
    }
}
