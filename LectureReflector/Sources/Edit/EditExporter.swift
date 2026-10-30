import Foundation
import AVFoundation

/// Writes lecture-edited.mp4, .srt and .txt from a session folder's
/// lecture.mp4, lecture-words.json and edited lecture-edit.txt.
enum EditExporter {
    static let outputName = "lecture-edited"

    /// Each cut gets a short fade out and in, so the audio doesn't click.
    static let fade: TimeInterval = 0.015

    struct Result {
        var plan: EditPlan
        var videoURL: URL

        var summary: String {
            var parts = [String(format: "Removed %@ (%d word%@",
                                 Self.duration(plan.removedSeconds),
                                 plan.deletedWordCount, plan.deletedWordCount == 1 ? "" : "s")]
            parts[0] += plan.deletedLineCount > 0
                ? ", including \(plan.deletedLineCount) whole line\(plan.deletedLineCount == 1 ? "" : "s"))."
                : ")."
            parts.append("Saved \(videoURL.lastPathComponent) with a matching transcript and captions.")
            if !plan.ignoredAddedWords.isEmpty {
                let sample = plan.ignoredAddedWords.prefix(5).joined(separator: ", ")
                parts.append("Ignored \(plan.ignoredAddedWords.count) word(s) that aren't in the recording (\(sample)); the video can only be cut.")
            }
            if plan.untaggedLineCount > 0 {
                parts.append("Skipped \(plan.untaggedLineCount) line(s) without a [number @ time] tag.")
            }
            return parts.joined(separator: " ")
        }

        static func duration(_ seconds: TimeInterval) -> String {
            let s = Int(seconds.rounded())
            return s >= 60 ? "\(s / 60) min \(s % 60) s" : "\(s) s"
        }
    }

    static func hasWordTimes(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(WordTranscript.fileName).path)
    }

    static func cut(folder: URL, progress: @escaping (String) -> Void) async throws -> Result {
        let source = folder.appendingPathComponent("lecture.mp4")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw LectureReflectorError("There's no lecture.mp4 in “\(folder.lastPathComponent)”.")
        }
        let transcript: WordTranscript
        do {
            transcript = try WordTranscript.load(from: folder)
        } catch {
            throw LectureReflectorError("This recording has no word timing yet (\(WordTranscript.fileName)). Transcribe it again with word timing first.")
        }
        let editURL = folder.appendingPathComponent(TranscriptEdit.editFileName)
        guard let editText = try? String(contentsOf: editURL, encoding: .utf8) else {
            throw LectureReflectorError("There's no \(TranscriptEdit.editFileName) in “\(folder.lastPathComponent)”.")
        }

        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        let plan = TranscriptEdit.plan(transcript: transcript, editText: editText, duration: duration)
        guard !plan.keep.isEmpty else {
            throw LectureReflectorError("The edited transcript removes the whole recording.")
        }

        progress("Cutting the video…")
        let composition = AVMutableComposition()
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let compVideo = videoTrack == nil ? nil
            : composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let compAudio = audioTrack == nil ? nil
            : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        if let videoTrack, let compVideo {
            compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        }

        let scale: CMTimeScale = 600
        var cursor = CMTime.zero
        var mixParameters: AVMutableAudioMixInputParameters?
        if let compAudio { mixParameters = AVMutableAudioMixInputParameters(track: compAudio) }

        for (index, span) in plan.keep.enumerated() {
            let range = CMTimeRange(
                start: CMTime(seconds: span.start, preferredTimescale: scale),
                end: CMTime(seconds: span.end, preferredTimescale: scale)
            )
            if let videoTrack, let compVideo {
                try compVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            }
            if let audioTrack, let compAudio {
                try compAudio.insertTimeRange(range, of: audioTrack, at: cursor)
            }
            let fade = CMTime(seconds: min(Self.fade, span.duration / 2), preferredTimescale: scale)
            if index > 0 {
                mixParameters?.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                                             timeRange: CMTimeRange(start: cursor, duration: fade))
            }
            cursor = cursor + range.duration
            if index < plan.keep.count - 1 {
                mixParameters?.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                             timeRange: CMTimeRange(start: cursor - fade, duration: fade))
            }
        }

        let output = folder.appendingPathComponent("\(outputName).mp4")
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw LectureReflectorError("Could not create the video exporter.")
        }
        export.outputURL = output
        export.outputFileType = .mp4
        if let mixParameters {
            let mix = AVMutableAudioMix()
            mix.inputParameters = [mixParameters]
            export.audioMix = mix
        }
        progress("Writing \(output.lastPathComponent)… this takes a while for a long lecture.")
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? LectureReflectorError("Writing the edited video failed.")
        }

        try TranscriptEdit.srtText(plan.segments)
            .write(to: folder.appendingPathComponent("\(outputName).srt"), atomically: true, encoding: .utf8)
        try plan.segments.map(\.text).joined(separator: "\n")
            .write(to: folder.appendingPathComponent("\(outputName).txt"), atomically: true, encoding: .utf8)
        try writeCutList(plan, to: folder.appendingPathComponent("\(outputName)-cuts.txt"), duration: duration)

        return Result(plan: plan, videoURL: output)
    }

    /// A readable list of what was cut, for checking whether word timing
    /// clipped anything.
    private static func writeCutList(_ plan: EditPlan, to url: URL, duration: TimeInterval) throws {
        var lines = ["Kept parts of lecture.mp4 (original clock → edited clock):"]
        var elapsed: TimeInterval = 0
        for span in plan.keep {
            lines.append(String(format: "  %@–%@  →  %@ (%.2f s)",
                                precise(span.start), precise(span.end), precise(elapsed), span.duration))
            elapsed += span.duration
        }
        lines.append(String(format: "Original %.1f s, edited %.1f s, removed %.1f s.", duration, elapsed, plan.removedSeconds))
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func precise(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}
