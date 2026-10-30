import SwiftUI

@main
struct LectureReflectorApp: App {
    @StateObject private var session = RecordingSession()

    init() {
        // Developer path: `LectureReflector --level <file.mp4> [--no-cleanup]`
        // runs the level correction on an existing recording (rewritten in
        // place), prints the audio-check lines and quits without opening a window.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--level"), index + 1 < args.count {
            let url = URL(fileURLWithPath: args[index + 1])
            let cleanup = !args.contains("--no-cleanup")
            Task {
                do {
                    print(try await AudioLeveler.normalize(fileAt: url, cleanup: cleanup))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
        }
        Window("Monitor", id: "monitor") {
            MonitorView()
                .environmentObject(session)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)
    }
}
