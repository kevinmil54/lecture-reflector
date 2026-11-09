import SwiftUI
import AppKit

/// A small always-on-top panel for the lecturer's eyes: recording time, the
/// current slide and how long it has been up, and the mic meter with the
/// audio check. Meant to sit beside the deck's speaker view while the main
/// Lecture Reflector window stays out of the way. The window is excluded
/// from screen capture, so it never appears in an *Entire screen* recording.
struct MonitorView: View {
    @EnvironmentObject private var session: RecordingSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .top, spacing: 16) {
                preview
                VStack(alignment: .leading, spacing: 12) {
                    timing(now: context.date)
                    Divider()
                    switchButtons
                    HStack(spacing: 6) {
                        Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                        Slider(value: $session.cameraZoom, in: 1...4)
                        Text(String(format: "%.1f×", session.cameraZoom)).font(.caption).monospacedDigit().frame(width: 32, alignment: .trailing)
                    }
                    .help("Camera zoom")
                    Divider()
                    mic
                }
                .frame(width: 300, alignment: .leading)
            }
            .padding(16)
        }
        .background(FloatingWindow())
    }

    // MARK: Timing

    private func timing(now: Date) -> some View {
        let elapsed = session.isPaused ? session.pausedElapsed : (session.recordedSeconds ?? 0)
        let changes = session.slideChanges
        let onSlide = elapsed - (changes.last ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                switch session.phase {
                case .recording where session.isPaused:
                    Image(systemName: "pause.fill").foregroundStyle(.orange)
                case .recording:
                    Circle().fill(.red).frame(width: 10, height: 10)
                default:
                    Circle().fill(.gray).frame(width: 10, height: 10)
                }
                Text(timeString(elapsed))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .monospacedDigit()
            }
            if session.phase == .recording, session.cameraFullScreenActive {
                Label("Camera full screen (\(HotKeys.cameraLabel) to go back)", systemImage: "person.fill")
                    .font(.callout)
                    .foregroundStyle(.purple)
            } else if session.phase == .recording, let demo = session.demoAppName {
                Label("Recording \(demo)", systemImage: "cursorarrow.rays")
                    .font(.callout)
                    .foregroundStyle(.blue)
            } else if session.phase == .recording {
                if session.slidesSourceIsWindow == false, !session.slideSourceStatus.isEmpty {
                    Text("Recording: \(session.slideSourceStatus)  (\(HotKeys.switchScreenLabel) to switch)")
                        .font(.callout)
                        .foregroundStyle(.blue)
                }
                Text("Slide \(changes.count + 1)  ·  \(timeString(onSlide)) on this slide")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text(session.phase == .finishing ? "Finalizing…" : "Not recording")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Preview

    /// What is being recorded, live, with the name of the app on screen.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Color.black
                if let image = session.previewImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("Start the preview to see what is recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let value = session.countdownValue {
                    Text("\(value)")
                        .font(.system(size: 110, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(radius: 12)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(width: 400)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            if session.phase != .idle {
                Label(session.slidesSourceIsWindow ? session.activeTarget.label : session.slideSourceStatus,
                      systemImage: "record.circle")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            recordControls
        }
        .frame(width: 400)
    }

    // MARK: Record / stop (same actions as the main window)

    @ViewBuilder
    private var recordControls: some View {
        switch session.phase {
        case .idle:
            Button {
                Task { await session.startPreview() }
            } label: {
                Label("Start Preview", systemImage: "eye").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

        case .previewing:
            Button {
                Task { await session.startRecording() }
            } label: {
                Label("Record", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(session.transcribing)

        case .countdown:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(session.countdownValue.map { "Starting in \($0)…" } ?? "Starting…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

        case .recording:
            HStack(spacing: 8) {
                Button {
                    Task { await session.stopRecording() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                Button(session.isPaused ? "Resume" : "Pause") {
                    session.togglePause()
                }
                .controlSize(.large)
            }

        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finalizing…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Switching

    /// Click to record that window. The current one is marked.
    private var targetList: some View {
        let active = session.activeTarget
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Record").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(HotKeys.switchAppLabel) = next").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(session.targets) { target in
                Button {
                    Task { await session.select(target) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: target == active ? "record.circle.fill" : "circle")
                            .foregroundStyle(target == active ? Color.red : Color.secondary)
                        Text(target.label).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.callout.weight(target == active ? .semibold : .regular))
            }
            if session.targets.count == 1 {
                Text("Add apps or windows in the main window.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var switchButtons: some View {
        let live = session.phase == .previewing || session.phase == .recording || session.phase == .countdown
        return VStack(spacing: 8) {
        if session.slidesSourceIsWindow {
            targetList
        }
        HStack(spacing: 8) {
            Button {
                Task { await session.switchScreen() }
            } label: {
                Label("Switch Screen", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .help("Record the other screen (\(HotKeys.switchScreenLabel))")
            Button {
                session.toggleCameraFullScreen()
            } label: {
                Label(session.cameraFullScreenActive ? "Back to Screen" : "Camera Only", systemImage: "person.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(session.cameraFullScreenActive ? .purple : nil)
            .help("Record just the camera, full screen, until pressed again (\(HotKeys.cameraLabel))")
        }
        if session.secondCameraID != nil {
            Button {
                session.switchCamera()
            } label: {
                Label(session.usingSecondCamera ? "Camera 2 live — use Camera 1" : "Camera 1 live — use Camera 2", systemImage: "camera.rotate")
                    .frame(maxWidth: .infinity)
            }
            .help("Switch cameras (\(HotKeys.switchCameraLabel))")
        }
        }
        .controlSize(.large)
        .disabled(!live)
    }

    // MARK: Mic

    private var mic: some View {
        let q = session.audioQuality
        let color: Color
        switch q.status {
        case .good: color = .green
        case .low, .waiting, .unreadable: color = .orange
        case .clipping, .noise, .silent: color = .red
        }
        // dBFS roughly -50…0 mapped to 0…1, as in the main window.
        let normalized = max(0, min(1, (session.audioLevel + 50) / 50))
        return VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(normalized))
                .tint(normalized > 0.9 ? .red : .green)
            Label(q.status.rawValue, systemImage: q.status.isProblem ? "exclamationmark.triangle.fill" : "circle.fill")
                .foregroundStyle(color)
                .font(.callout)
                .lineLimit(2)
            if q.status != .waiting && q.status != .unreadable {
                Text(String(format: "Speech %.0f dB · Floor %.0f dB · Peak %.0f dB", q.speechLevel, q.floor, q.peak))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
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

/// Keeps the hosting window above other windows (including a full-screen
/// deck on the same display) and out of screen captures.
private struct FloatingWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.sharingType = .none
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
