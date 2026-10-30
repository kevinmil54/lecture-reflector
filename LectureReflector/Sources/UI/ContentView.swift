import SwiftUI
import ScreenCaptureKit
import AVFoundation

struct ContentView: View {
    @EnvironmentObject var session: RecordingSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 310, idealWidth: 340, maxWidth: 390)
            preview
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 920, minHeight: 560)
        .task {
            await session.refreshSources()
        }
        .alert(
            "LectureReflector",
            isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            ),
            actions: { Button("OK") { session.errorMessage = nil } },
            message: { Text(session.errorMessage ?? "") }
        )
    }

    // MARK: - Left panel

    private var controls: some View {
        Form {
            Section("Sources") {
                Picker("Slides", selection: $session.selectedSourceID) {
                    Section("Windows") {
                        ForEach(session.windows, id: \.windowID) { window in
                            Text(windowLabel(window)).tag(Optional(RecordingSession.sourceID(window)))
                        }
                    }
                    Section("Entire screen (best for full-screen presenting)") {
                        ForEach(Array(session.displays.enumerated()), id: \.element.displayID) { index, display in
                            Text("Screen \(index + 1) — \(display.width)×\(display.height)")
                                .tag(Optional(RecordingSession.sourceID(display)))
                        }
                    }
                }
                if session.phase != .idle, !session.slideSourceStatus.isEmpty {
                    LabeledContent("Capturing") {
                        Text(session.slideSourceStatus)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(session.slideSourceStatus)
                    }
                    .font(.caption)
                }
                Picker("Camera", selection: $session.selectedCameraID) {
                    ForEach(session.cameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                Picker("Microphone", selection: $session.selectedMicID) {
                    ForEach(session.microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(Optional(device.uniqueID))
                    }
                }
                if session.phase != .idle {
                    LabeledContent("Mic level") {
                        micMeter
                    }
                    LabeledContent("Audio check") {
                        audioCheck
                    }
                    Button("Open Monitor Panel") {
                        openWindow(id: "monitor")
                    }
                    .help("A small always-on-top panel with the recording time, current slide, and mic meter. Put it next to your deck's speaker view.")
                }
                Button("Refresh Sources") {
                    Task { await session.refreshSources() }
                }
                .disabled(session.phase != .idle)
            }

            Section("Demo apps") {
                let choices = session.demoAppChoices
                if choices.isEmpty {
                    Text("Open the apps you want to demonstrate, then click Refresh Sources.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(choices) { choice in
                        Toggle(choice.name, isOn: Binding(
                            get: { session.demoApps[choice.id] != nil },
                            set: { session.setDemoApp(choice, enabled: $0) }
                        ))
                    }
                }
                Text(session.slidesSourceIsWindow
                     ? "While one of these apps is in front, its window is recorded instead of the slides, with the mouse pointer. Switch back to your slides app to return."
                     : "Demo apps need a window as the Slides source, not Entire screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Crop slides") {
                cropSlider("Top", value: $session.slideCrop.top, range: 0...300)
                cropSlider("Bottom", value: $session.slideCrop.bottom, range: 0...200)
                cropSlider("Left", value: $session.slideCrop.left, range: 0...300)
                cropSlider("Right", value: $session.slideCrop.right, range: 0...300)
                HStack {
                    Text("Trims the browser toolbar or window edges. Remembered for each app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("No Crop") {
                        session.slideCrop = .none
                        session.saveSlideCrop()
                    }
                    .disabled(session.slideCrop.isEmpty)
                }
            }

            Section("Layout") {
                Picker("Lecturer", selection: $session.layout) {
                    ForEach(Layout.allCases) { layout in
                        Label(layout.rawValue, systemImage: layout.systemImage).tag(layout)
                    }
                }
                if session.layout == .sidebar {
                    Text("Sidebar records a wider 1600×720 frame so the slides keep their full size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.layout == .floatingTorso {
                    Text("Floating Torso cuts you out of the background and overlays you on the slides.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if session.layout.hasMovableSlides {
                    Text("In the preview, drag a box to move it and drag a corner to resize it: orange for the slides, blue for you. Works while recording too.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Full-Screen Slides") {
                            session.resetSlidePlacement()
                        }
                        if session.layout.hasMovableLecturer {
                            Button("Reset Lecturer") {
                                session.resetPlacement(for: session.layout)
                            }
                        }
                    }
                }
            }

            Section("Output") {
                TextField("Lecture title", text: $session.lectureTitle)
                LabeledContent("Save to") {
                    Text(session.outputFolder.lastPathComponent)
                        .truncationMode(.middle)
                        .help(session.outputFolder.path)
                }
                Button("Choose Folder…") {
                    session.chooseOutputFolder()
                }
                .disabled(session.phase == .recording || session.phase == .finishing)
            }

            Section("Settings") {
                Picker("Whisper model", selection: $session.whisperModel) {
                    ForEach(RecordingSession.whisperModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .disabled(session.transcribing)
                Toggle("Mirror camera", isOn: $session.mirrorCamera)
                Toggle("3-second countdown", isOn: $session.countdownEnabled)
                Toggle("Show mouse pointer in slides", isOn: $session.showCursor)
                    .help("Off by default. Turn on if you point at things with the mouse while lecturing.")
                Toggle("Correct audio level after recording", isOn: $session.autoLevelEnabled)
                    .help("Raises or lowers the finished recording's audio to a standard loudness (-16 LUFS) without clipping. The video is not re-encoded.")
                Toggle("Clean up voice after recording", isOn: $session.voiceCleanupEnabled)
                    .disabled(!session.autoLevelEnabled)
                    .help("Before the level correction: removes room rumble below 80 Hz, adds a little presence above 3 kHz, and evens out the loudest moments so the limiter rarely has to act.")
            }

            Section {
                actionButtons
            }

            if session.transcribing || session.editing || !session.statusMessage.isEmpty {
                Section("Transcript") {
                    HStack(spacing: 8) {
                        if session.transcribing || session.editing {
                            ProgressView().controlSize(.small)
                        }
                        Text(session.statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if session.lastOutputFolder != nil {
                Section {
                    Button("Show Recording in Finder") {
                        session.revealLastOutput()
                    }
                }
            }

            Section("Edit by transcript") {
                Text("Delete lines or words in a recording's lecture-edit.txt, then cut the video to match. The original recording is not changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if session.lastOutputFolder != nil {
                    Button("Open Transcript for Editing") {
                        session.openEditFileForLastRecording()
                    }
                    .disabled(session.transcribing || session.editing)
                }
                Button("Cut Video from Edited Transcript…") {
                    Task { await session.cutFromEditedTranscript() }
                }
                .disabled(session.transcribing || session.editing
                          || session.phase == .recording || session.phase == .finishing)
            }
        }
        .formStyle(.grouped)
    }

    private var audioCheck: some View {
        let q = session.audioQuality
        let color: Color
        switch q.status {
        case .good: color = .green
        case .low, .waiting, .unreadable: color = .orange
        case .clipping, .noise, .silent: color = .red
        }
        return VStack(alignment: .trailing, spacing: 2) {
            Label(q.status.rawValue, systemImage: q.status.isProblem ? "exclamationmark.triangle.fill" : "circle.fill")
                .foregroundStyle(color)
                .font(.callout)
            if q.status != .waiting && q.status != .unreadable {
                Text(String(format: "Speech %.0f dB · Quiet floor %.0f dB · Peak %.0f dB", q.speechLevel, q.floor, q.peak))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Speech should reach about -20 to -10 dB. The quiet floor (pauses) should be below -45 dB; a high floor means static or loud background noise.")
    }

    private var micMeter: some View {
        // dBFS roughly -50…0 mapped to 0…1.
        let normalized = max(0, min(1, (session.audioLevel + 50) / 50))
        return ProgressView(value: Double(normalized))
            .tint(normalized > 0.9 ? .red : .green)
            .frame(width: 120)
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch session.phase {
        case .idle:
            Button {
                Task { await session.startPreview() }
            } label: {
                Label("Start Preview", systemImage: "eye")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

        case .previewing:
            VStack(spacing: 8) {
                Button {
                    Task { await session.startRecording() }
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(session.transcribing)

                Button("Stop Preview") {
                    Task { await session.stopPreview() }
                }
            }

        case .countdown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting…")
                    .foregroundStyle(.secondary)
            }

        case .recording:
            VStack(spacing: 8) {
                Button {
                    Task { await session.stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)

                Button(session.isPaused ? "Resume" : "Pause") {
                    session.togglePause()
                }

                if session.isPaused {
                    HStack(spacing: 6) {
                        Image(systemName: "pause.fill")
                        Text("Paused at \(timeString(session.pausedElapsed))")
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                } else if let started = session.recordingStartedAt {
                    HStack(spacing: 6) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text(started, style: .timer)
                            .monospacedDigit()
                    }
                    .font(.callout)
                }
            }

        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finalizing video…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Right panel

    private var preview: some View {
        ZStack {
            Color.black
            if let image = session.previewImage {
                GeometryReader { geometry in
                    let canvas = CGSize(width: image.width, height: image.height)
                    ZStack(alignment: .topLeading) {
                        Image(decorative: image, scale: 1.0)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        let imageFrame = Self.fittedRect(canvas, in: geometry.size)
                        if session.layout.hasMovableSlides {
                            PlacementEditor(
                                placement: session.slidePlacement,
                                aspect: canvas.width / max(canvas.height, 1),
                                maxWidth: 1,
                                isCircle: false,
                                tint: .orange,
                                canvas: canvas,
                                imageFrame: imageFrame,
                                onChange: { session.setSlidePlacement($0, canvas: canvas) },
                                onEnd: { session.saveSlidePlacement() }
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                        if session.layout.hasMovableLecturer {
                            PlacementEditor(
                                placement: session.placement(for: session.layout),
                                aspect: session.layout.lecturerAspect,
                                maxWidth: LecturerPlacement.maxWidth,
                                isCircle: session.layout == .circlePiP,
                                tint: .accentColor,
                                canvas: canvas,
                                imageFrame: imageFrame,
                                onChange: { session.setPlacement($0, for: session.layout, canvas: canvas) },
                                onEnd: { session.savePlacements() }
                            )
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 40))
                    Text("Pick your slides window and camera,\nthen click Start Preview.")
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
            }

            if let value = session.countdownValue {
                Text("\(value)")
                    .font(.system(size: 140, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 12)
            }

            if session.phase == .recording {
                VStack {
                    HStack {
                        Label(session.isPaused ? "PAUSED" : "REC", systemImage: session.isPaused ? "pause.fill" : "record.circle.fill")
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(session.isPaused ? Color.orange : Color.red, in: Capsule())
                            .foregroundStyle(.white)
                        if let demo = session.demoAppName {
                            Label("Demo: \(demo)", systemImage: "cursorarrow.rays")
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.blue, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
    }

    private func cropSlider(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: 1) { editing in
                    if !editing { session.saveSlideCrop() }
                }
                Text("\(Int(value.wrappedValue)) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    static func fittedRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    private func windowLabel(_ window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "App"
        let title = window.title ?? ""
        return title.isEmpty ? app : "\(app) — \(title)"
    }

    private func timeString(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let minutes = (Int(time) / 60) % 60
        let hours = Int(time) / 3600
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Editable outline of a box (the slides or the lecturer) drawn over the live
/// preview. Drag inside to move, drag a corner to resize (aspect kept). It is a
/// SwiftUI overlay, so it never appears in the recording.
@MainActor
private struct PlacementEditor: View {
    let placement: LecturerPlacement
    /// Width ÷ height of the box.
    let aspect: CGFloat
    let maxWidth: CGFloat
    let isCircle: Bool
    let tint: Color
    /// Pixel size of the composited frame shown in the preview.
    let canvas: CGSize
    /// Where that frame is drawn inside the preview pane.
    let imageFrame: CGRect
    let onChange: (LecturerPlacement) -> Void
    let onEnd: () -> Void

    @State private var dragStart: LecturerPlacement?
    @State private var hovering = false

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var isRight: Bool { self == .topRight || self == .bottomRight }
        var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    }

    private var scale: CGFloat { canvas.width > 0 ? imageFrame.width / canvas.width : 1 }

    private var current: LecturerPlacement {
        placement.clamped(canvas: canvas, aspect: aspect, maxWidth: maxWidth)
    }

    /// Box in preview-pane coordinates.
    private var box: CGRect {
        let rect = current.rect(in: canvas, aspect: aspect)
        return CGRect(
            x: imageFrame.minX + rect.minX * scale,
            y: imageFrame.minY + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    var body: some View {
        let box = self.box
        let active = hovering || dragStart != nil
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .allowsHitTesting(false)

            outline
                .frame(width: box.width, height: box.height)
                .contentShape(Rectangle())
                .position(x: box.midX, y: box.midY)
                .opacity(active ? 1 : 0.35)
                .onHover { hovering = $0 }
                .gesture(moveGesture)

            ForEach(Corner.allCases, id: \.self) { corner in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(tint, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle().inset(by: -6))
                    .position(
                        x: corner.isRight ? box.maxX - 6 : box.minX + 6,
                        y: corner.isBottom ? box.maxY - 6 : box.minY + 6
                    )
                    .opacity(active ? 1 : 0.35)
                    .onHover { hovering = $0 }
                    .gesture(resizeGesture(corner))
            }
        }
    }

    @ViewBuilder
    private var outline: some View {
        let stroke = StrokeStyle(lineWidth: 2, dash: [6, 4])
        if isCircle {
            Circle().stroke(tint, style: stroke)
        } else {
            Rectangle().stroke(tint, style: stroke)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? current
                dragStart = start
                var moved = start
                moved.x += value.translation.width / (canvas.width * scale)
                moved.y += value.translation.height / (canvas.height * scale)
                onChange(moved)
            }
            .onEnded { _ in
                dragStart = nil
                onEnd()
            }
    }

    /// Resizes keeping the aspect ratio, with the opposite corner held still.
    private func resizeGesture(_ corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? current
                dragStart = start
                let startRect = start.rect(in: canvas, aspect: aspect)
                // Translation in canvas pixels, signed so that "outward" grows the box.
                let dx = value.translation.width / scale * (corner.isRight ? 1 : -1)
                let dy = value.translation.height / scale * (corner.isBottom ? 1 : -1) * aspect
                let growth = abs(dx) >= abs(dy) ? dx : dy
                let largest = min(maxWidth * canvas.width, canvas.height * aspect)
                let newWidth = min(max(startRect.width + growth, LecturerPlacement.minWidth * canvas.width), largest)
                let newHeight = newWidth / aspect
                let originX = corner.isRight ? startRect.minX : startRect.maxX - newWidth
                let originY = corner.isBottom ? startRect.minY : startRect.maxY - newHeight
                onChange(LecturerPlacement(
                    x: originX / canvas.width,
                    y: originY / canvas.height,
                    width: newWidth / canvas.width
                ))
            }
            .onEnded { _ in
                dragStart = nil
                onEnd()
            }
    }
}
