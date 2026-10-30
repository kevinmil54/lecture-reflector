import Foundation
import AVFoundation
import WhisperKit

struct TranscriptSegment {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// On-device Whisper transcription via WhisperKit (Core ML). The model is
/// downloaded from Hugging Face on first use and cached locally after that.
final class Transcriber {
    func transcribe(mediaURL: URL, model: String, progress: @escaping (String) -> Void) async throws -> [TranscriptSegment] {
        progress("Extracting audio…")
        let audioURL = mediaURL.deletingLastPathComponent().appendingPathComponent("lecture-audio.m4a")
        try await extractAudio(from: mediaURL, to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        progress("Loading Whisper model “\(model)” (downloads on first run)…")
        let whisper = try await WhisperKit(model: model)

        progress("Transcribing… this can take a few minutes for a long lecture.")
        let results = try await whisper.transcribe(audioPath: audioURL.path)

        let tokenPattern = try NSRegularExpression(pattern: "<\\|[^|]*\\|>")
        var segments: [TranscriptSegment] = []
        for result in results {
            for segment in result.segments {
                var text = segment.text
                text = tokenPattern.stringByReplacingMatches(
                    in: text,
                    range: NSRange(text.startIndex..., in: text),
                    withTemplate: ""
                )
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    start: TimeInterval(segment.start),
                    end: TimeInterval(segment.end),
                    text: text
                ))
            }
        }
        return segments
    }

    static func writeTranscript(_ segments: [TranscriptSegment], to folder: URL) throws {
        let text = segments.map(\.text).joined(separator: "\n")
        try text.write(to: folder.appendingPathComponent("lecture.txt"), atomically: true, encoding: .utf8)

        var srt = ""
        for (index, segment) in segments.enumerated() {
            srt += "\(index + 1)\n"
            srt += "\(srtTime(segment.start)) --> \(srtTime(segment.end))\n"
            srt += "\(segment.text)\n\n"
        }
        try srt.write(to: folder.appendingPathComponent("lecture.srt"), atomically: true, encoding: .utf8)
    }

    private func extractAudio(from url: URL, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw LectureReflectorError("Could not create the audio exporter")
        }
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        if export.status != .completed {
            throw export.error ?? LectureReflectorError("Audio extraction failed")
        }
    }

    private static func srtTime(_ time: TimeInterval) -> String {
        let milliseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 1000)
        let seconds = Int(time) % 60
        let minutes = (Int(time) / 60) % 60
        let hours = Int(time) / 3600
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, milliseconds)
    }
}
