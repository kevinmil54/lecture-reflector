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
            VStack(alignment: .leading, spacing: 12) {
                timing(now: context.date)
                Divider()
                mic
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
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
            if session.phase == .recording, let demo = session.demoAppName {
                Label("Recording \(demo)", systemImage: "cursorarrow.rays")
                    .font(.callout)
                    .foregroundStyle(.blue)
            } else if session.phase == .recording {
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
