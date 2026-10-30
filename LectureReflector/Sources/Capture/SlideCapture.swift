import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreImage
import Metal

/// Captures the slides via ScreenCaptureKit and keeps the most recent frame.
/// ScreenCaptureKit only delivers frames when the content changes, so the
/// compositor pulls `latestPixelBuffer` on its own 30 fps clock.
///
/// Two kinds of source:
/// - A window (PowerPoint, Keynote, a browser showing reveal.js/Quarto). The
///   capture *follows* the presentation: browsers and Keynote often move the
///   deck into a different window when it goes full screen (Safari's element
///   full screen, reveal.js's "F" key, Keynote's Play), which used to leave the
///   recording stuck on the first slide. A watchdog notices this and switches
///   to the app's full-screen window, and back again when it closes.
/// - A whole display (minus Lecture Reflector itself). Always shows whatever is
///   on that screen; the most reliable choice for full-screen presenting.
///
/// Demo apps (window sources only): while one of the lecturer's chosen demo
/// apps (e.g. Obsidian, Zotero) is the frontmost app, the capture switches to
/// that app's front window, with the mouse pointer and without the slide crop.
/// Bringing the slides app back to the front returns to the slides. Clicking
/// Lecture Reflector itself, or any other app, leaves the capture where it is.
final class SlideCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Source {
        case window(SCWindow)
        case display(SCDisplay)
    }

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "lecture_reflector.slides", qos: .userInitiated)
    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    /// Last full (uncropped) frame, so a crop change shows up immediately
    /// even while the slide sits still. Touched only on sampleQueue.
    private var lastFull: CVPixelBuffer?
    /// Size in points of what is being captured (window or display).
    private var _sourcePointSize: CGSize = .zero
    private var _crop = SlideCrop.none
    private var _streamFailed = false

    // Window-following state (touched by start/stop and the watchdog task only).
    private var followedPID: pid_t?
    private var followedTitle: String?
    private var currentWindowID: CGWindowID?
    private var currentWindowSize: CGSize = .zero
    private var watchdog: Task<Void, Never>?

    // Demo state. `_demoActive` and `_demoBundleIDs` are read from several
    // queues, so they sit behind `lock`; the rest is touched by start/stop
    // and the watchdog only.
    private var _demoActive = false
    private var _demoBundleIDs: Set<String> = []
    /// The slides window to return to after a demo.
    private var slideWindowID: CGWindowID?
    /// The demo app currently shown, so a switch between demo apps is reported.
    private var demoPID: pid_t?

    // Frames are copied out of ScreenCaptureKit's buffer pool into our own
    // buffers. Holding on to SCK's IOSurfaces (as the compositor and chapter
    // detector do) can stall the stream so new slides never arrive.
    private let copyContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private var copyPool: CVPixelBufferPool?
    private var copyPoolSize: (Int, Int) = (0, 0)

    /// Human-readable description of what is being captured, for the UI.
    /// Called on an arbitrary queue.
    var onSourceChanged: ((String) -> Void)?

    /// Called when a demo app's window replaces the slides (with the app's
    /// name), when the demo switches to another app, and with nil when the
    /// slides come back. Called on an arbitrary queue.
    var onDemoChanged: ((String?) -> Void)?

    /// Bundle IDs of the apps whose windows replace the slides while frontmost.
    var demoBundleIDs: Set<String> {
        get { lock.withLock { _demoBundleIDs } }
        set { lock.withLock { _demoBundleIDs = newValue } }
    }

    /// True while a demo app's window is being captured instead of the slides.
    var isDemoActive: Bool {
        lock.withLock { _demoActive }
    }

    /// Whether the mouse pointer is drawn into the captured slides. Off by
    /// default: a pointer wandering over the deck is a distraction in the
    /// recording. Call `applyConfiguration()` after changing it mid-capture.
    static var showsCursor = false

    /// Re-sends the stream configuration to a running stream, e.g. after
    /// `showsCursor` changes.
    func applyConfiguration() async {
        guard let stream else { return }
        let (size, demo) = lock.withLock { (_sourcePointSize, _demoActive) }
        guard size.width > 0, size.height > 0 else { return }
        try? await stream.updateConfiguration(Self.configuration(for: size, cursor: demo || Self.showsCursor))
    }

    var latestPixelBuffer: CVPixelBuffer? {
        lock.withLock { _latest }
    }

    /// Edges trimmed off the captured window, in points (e.g. Safari's toolbar).
    var crop: SlideCrop {
        get { lock.withLock { _crop } }
        set {
            lock.withLock { _crop = newValue }
            sampleQueue.async { [weak self] in
                guard let self, let full = self.lastFull else { return }
                let cropped = self.cropFrame(full) ?? full
                self.lock.withLock { self._latest = cropped }
            }
        }
    }

    /// Windows a lecturer might present from: on screen, normal layer, big enough
    /// to plausibly be a slide deck, and not LectureReflector itself.
    static func availableWindows() async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.filter(isCandidate)
    }

    static func availableDisplays() async throws -> [SCDisplay] {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).displays
    }

    private static func isCandidate(_ window: SCWindow) -> Bool {
        guard let app = window.owningApplication else { return false }
        return app.bundleIdentifier != Bundle.main.bundleIdentifier
            && window.windowLayer == 0
            && window.frame.width >= 400
            && window.frame.height >= 300
    }

    // MARK: - Start / stop

    func start(source: Source) async throws {
        await stop()
        switch source {
        case .window(let window):
            followedPID = window.owningApplication?.processID
            followedTitle = window.title
            try await startStream(window: window)
            startWatchdog()
        case .display(let display):
            try await startStream(display: display)
        }
    }

    func stop() async {
        watchdog?.cancel()
        if let watchdog { await watchdog.value }
        watchdog = nil
        await stopStream()
        followedPID = nil
        followedTitle = nil
        currentWindowID = nil
        slideWindowID = nil
        demoPID = nil
        lock.withLock {
            _latest = nil
            _demoActive = false
        }
        sampleQueue.async { [weak self] in self?.lastFull = nil }
    }

    private func stopStream() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
    }

    /// `demo` marks a demo app's window: pointer always shown, no slide crop.
    private func startStream(window: SCWindow, demo: Bool = false) async throws {
        await stopStream()
        lock.withLock { _demoActive = demo }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = Self.configuration(for: window.frame.size, cursor: demo || Self.showsCursor)
        try await run(filter: filter, config: config)
        currentWindowID = window.windowID
        currentWindowSize = window.frame.size
        if !demo {
            slideWindowID = window.windowID
        }
        lock.withLock { _sourcePointSize = window.frame.size }
        let app = window.owningApplication?.applicationName ?? "App"
        let title = window.title ?? ""
        let label = title.isEmpty ? app : "\(app) — \(title)"
        onSourceChanged?(demo ? "Demo: \(label)" : label)
    }

    private func startStream(display: SCDisplay) async throws {
        await stopStream()
        lock.withLock { _demoActive = false }
        // Everything on that screen except Lecture Reflector's own windows.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = Self.configuration(for: CGSize(width: display.width, height: display.height), cursor: Self.showsCursor)
        try await run(filter: filter, config: config)
        currentWindowID = nil
        lock.withLock { _sourcePointSize = display.frame.size }
        onSourceChanged?("Entire screen (\(display.width)×\(display.height))")
    }

    private func run(filter: SCContentFilter, config: SCStreamConfiguration) async throws {
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        lock.withLock { _streamFailed = false }
        self.stream = stream
    }

    private static func configuration(for pointSize: CGSize, cursor: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        // Capture at 2x the point size (Retina), capped; the compositor scales
        // down to the output canvas.
        let scale = min(2.0, 3840 / max(pointSize.width, 1), 2160 / max(pointSize.height, 1))
        config.width = max(2, Int(pointSize.width * scale))
        config.height = max(2, Int(pointSize.height * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = cursor
        // Stretch the window's content to fill the buffer. Without this, a
        // window on a non-Retina screen (or one that just changed size) is
        // drawn at its own pixel size in the top-left corner of a larger,
        // mostly black frame, so the slides look small and off to one side.
        config.scalesToFit = true
        config.preservesAspectRatio = true
        return config
    }

    // MARK: - Following the presentation window

    /// Checks four times a second for a switch to or from a demo app (cheap:
    /// it asks only which app is frontmost), and once a second, outside a
    /// demo, whether the deck moved into another window.
    private func startWatchdog() {
        watchdog = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.checkDemo()
                tick += 1
                if tick % 4 == 0, !self.isDemoActive {
                    await self.checkWindow()
                }
            }
        }
    }

    // MARK: - Demo apps

    private func checkDemo() async {
        guard let slidesPID = followedPID else { return }
        let ids = demoBundleIDs
        let demo = isDemoActive
        guard !ids.isEmpty || demo else { return }

        let front = await MainActor.run { () -> (pid: pid_t, bundleID: String?)? in
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return (app.processIdentifier, app.bundleIdentifier)
        }
        // Clicking Lecture Reflector (or its monitor panel) changes nothing.
        guard let front, front.bundleID != Bundle.main.bundleIdentifier else { return }

        if front.pid == slidesPID {
            if demo {
                await leaveDemo()
            }
            return
        }
        // Some other app (Finder, Mail…): keep showing whatever is up.
        guard let bundleID = front.bundleID, ids.contains(bundleID),
              let target = Self.frontWindow(pid: front.pid)
        else { return }

        let failed = lock.withLock { _streamFailed }
        if demo, target.id == currentWindowID, !failed {
            // Same demo window; keep the capture sharp if it was resized.
            if let stream,
               abs(target.size.width - currentWindowSize.width) > 2
                || abs(target.size.height - currentWindowSize.height) > 2 {
                currentWindowSize = target.size
                lock.withLock { _sourcePointSize = target.size }
                try? await stream.updateConfiguration(Self.configuration(for: target.size, cursor: true))
            }
            return
        }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == target.id })
        else { return }
        do {
            try await startStream(window: window, demo: true)
        } catch {
            return
        }
        if !demo || demoPID != front.pid {
            demoPID = front.pid
            onDemoChanged?(window.owningApplication?.applicationName ?? bundleID)
        }
    }

    /// Back to the slides window shown before the demo (or, if it is gone,
    /// the slides app's window with the same title, else its largest window).
    private func leaveDemo() async {
        lock.withLock { _demoActive = false }
        demoPID = nil
        onDemoChanged?(nil)
        guard let pid = followedPID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return }
        let onScreen = content.windows.filter {
            $0.owningApplication?.processID == pid && Self.isCandidate($0) && $0.isOnScreen
        }
        let target = onScreen.first { $0.windowID == slideWindowID }
            ?? onScreen.first { $0.title == followedTitle }
            ?? onScreen.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if let target {
            try? await startStream(window: target)
        }
    }

    /// The frontmost normal window of an app, by the window server's
    /// front-to-back order (ScreenCaptureKit's window list has no z-order).
    private static func frontWindow(pid: pid_t) -> (id: CGWindowID, size: CGSize)? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for entry in info {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsInfo = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary),
                  bounds.width >= 400, bounds.height >= 300
            else { continue }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha == 0 {
                continue
            }
            return (number, bounds.size)
        }
        return nil
    }

    private func checkWindow() async {
        guard let pid = followedPID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        else { return }

        let appWindows = content.windows.filter { $0.owningApplication?.processID == pid && Self.isCandidate($0) }
        let onScreen = appWindows.filter(\.isOnScreen)
        let current = appWindows.first { $0.windowID == currentWindowID }
        let failed = lock.withLock { _streamFailed }

        // A window of the presenting app that fills a whole display is the
        // presentation in full-screen mode.
        let fullScreen = onScreen.first { window in
            content.displays.contains { display in
                abs(window.frame.width - display.frame.width) < 2
                    && abs(window.frame.height - display.frame.height) < 2
            }
        }

        var replacement: SCWindow?
        if let fullScreen, fullScreen.windowID != currentWindowID,
           current.map({ !$0.isOnScreen || $0.frame.size != fullScreen.frame.size }) ?? true {
            // The deck went full screen in a new window (or a different window
            // took over the screen): follow it.
            replacement = fullScreen
        } else if current == nil || failed {
            // Our window closed (e.g. full screen ended): go back to the app's
            // window with the same title, else its largest visible window.
            replacement = onScreen.first { $0.title == followedTitle && $0.windowID != currentWindowID }
                ?? onScreen.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        }

        if let replacement {
            try? await startStream(window: replacement)
            return
        }

        // Same window, new size (e.g. Chrome going full screen in place):
        // update the capture resolution so the slides stay sharp.
        if let current, let stream,
           abs(current.frame.width - currentWindowSize.width) > 2
            || abs(current.frame.height - currentWindowSize.height) > 2 {
            currentWindowSize = current.frame.size
            lock.withLock { _sourcePointSize = current.frame.size }
            try? await stream.updateConfiguration(Self.configuration(for: current.frame.size, cursor: Self.showsCursor))
        }
    }

    // MARK: - SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let full = copyFrame(pixelBuffer)
        else { return }
        lastFull = full
        let cropped = cropFrame(full) ?? full
        lock.withLock { _latest = cropped }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Window closed or capture interrupted. Keep the last frame so the
        // recording shows a frozen slide rather than black; the watchdog will
        // try to pick the presentation back up.
        lock.withLock { _streamFailed = true }
    }

    /// GPU copy of an SCK frame into a buffer we own.
    private func copyFrame(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if copyPool == nil || copyPoolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            copyPool = pool
            copyPoolSize = (width, height)
        }
        guard let copyPool else { return nil }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, copyPool, &destination)
        guard let destination else { return nil }
        let image = CIImage(cvPixelBuffer: source)
        copyContext.render(image, to: destination, bounds: image.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        return destination
    }

    // MARK: - Cropping

    private var cropPool: CVPixelBufferPool?
    private var cropPoolSize: (Int, Int) = (0, 0)

    /// Trims the crop insets off a full frame. Returns nil when there is
    /// nothing to crop (the full frame is then used as is).
    private func cropFrame(_ full: CVPixelBuffer) -> CVPixelBuffer? {
        let (crop, pointSize, demo) = lock.withLock { (_crop, _sourcePointSize, _demoActive) }
        // The slide crop (e.g. Safari's toolbar) doesn't apply to a demo app.
        guard !demo, !crop.isEmpty, pointSize.width > 0, pointSize.height > 0 else { return nil }

        let bufferWidth = CGFloat(CVPixelBufferGetWidth(full))
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(full))
        // The window is scaled to fit the buffer with its aspect ratio kept,
        // so find where its content sits before converting points to pixels.
        let scale = min(bufferWidth / pointSize.width, bufferHeight / pointSize.height)
        let contentWidth = pointSize.width * scale
        let contentHeight = pointSize.height * scale
        let offsetX = (bufferWidth - contentWidth) / 2
        let offsetY = (bufferHeight - contentHeight) / 2

        // Core Image has a bottom-left origin, so "bottom" is the low-y edge.
        var rect = CGRect(
            x: offsetX + crop.left * scale,
            y: offsetY + crop.bottom * scale,
            width: contentWidth - (crop.left + crop.right) * scale,
            height: contentHeight - (crop.top + crop.bottom) * scale
        ).integral
        rect = rect.intersection(CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight))
        guard rect.width >= 32, rect.height >= 32 else { return nil }

        let width = Int(rect.width)
        let height = Int(rect.height)
        if cropPool == nil || cropPoolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            cropPool = pool
            cropPoolSize = (width, height)
        }
        guard let cropPool else { return nil }
        var destination: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, cropPool, &destination)
        guard let destination else { return nil }
        let image = CIImage(cvPixelBuffer: full)
            .cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        copyContext.render(image, to: destination, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpaceCreateDeviceRGB())
        return destination
    }
}

/// Edges trimmed off the captured slides, in points. Remembered per app so
/// Safari's toolbar crop is set once.
struct SlideCrop: Codable, Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    static let none = SlideCrop()
    var isEmpty: Bool { top <= 0 && bottom <= 0 && left <= 0 && right <= 0 }
}
