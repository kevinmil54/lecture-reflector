import Foundation

// Editing a recording by editing its transcript.
//
// After transcription, the session folder gets two extra files:
//   lecture-words.json  every segment with the start and end time of each word
//   lecture-edit.txt    one line per segment, e.g. "[12 @ 00:01:23] So today we…"
//
// The lecturer deletes whole lines or individual words from lecture-edit.txt
// in any text editor. "Cut Video from Edited Transcript" compares the edited
// lines with lecture-words.json, works out which stretches of time were
// deleted, and writes lecture-edited.mp4 (plus a matching .srt and .txt).
// Nothing here touches lecture.mp4 itself.

struct TranscriptWord: Codable, Equatable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

struct WordSegment: Codable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var words: [TranscriptWord]
}

struct WordTranscript: Codable {
    static let fileName = "lecture-words.json"
    var version = 1
    var segments: [WordSegment]

    static func load(from folder: URL) throws -> WordTranscript {
        let data = try Data(contentsOf: folder.appendingPathComponent(fileName))
        return try JSONDecoder().decode(WordTranscript.self, from: data)
    }

    func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// A stretch of the original recording, in seconds.
struct TimeSpan: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var duration: TimeInterval { end - start }
}

struct EditPlan {
    /// Parts of the original recording to keep, in order.
    var keep: [TimeSpan]
    /// Transcript segments as they will read in the edited video, with
    /// times on the edited video's clock.
    var segments: [WordSegment]
    var deletedWordCount: Int
    var deletedLineCount: Int
    /// Words typed into the edit file that aren't in the recording; they
    /// can't be added to the video and are ignored.
    var ignoredAddedWords: [String]
    /// Lines in the edit file without a "[n @ time]" tag.
    var untaggedLineCount: Int

    var removedSeconds: TimeInterval = 0
}

enum TranscriptEdit {
    static let editFileName = "lecture-edit.txt"

    /// Time kept around each remaining word so cuts don't clip it, and the
    /// shortest cut worth making.
    static let padding: TimeInterval = 0.08
    static let minimumCut: TimeInterval = 0.15

    // MARK: Edit file

    static func editFileText(_ transcript: WordTranscript) -> String {
        var lines = [
            "# Delete whole lines, or words within a line, then use",
            "# \"Cut Video from Edited Transcript\" in Lecture Reflector.",
            "# Keep the [number @ time] tag at the start of each line you keep.",
            "# Typing new words has no effect: the video can only be cut.",
            "",
        ]
        for (index, segment) in transcript.segments.enumerated() {
            lines.append("[\(index + 1) @ \(clock(segment.start))] \(segment.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The kept lines of an edit file: segment index (0-based) → remaining text.
    static func parseEditFile(_ text: String) -> (kept: [Int: String], untagged: Int) {
        var kept: [Int: String] = [:]
        var untagged = 0
        let tag = try! NSRegularExpression(pattern: #"^\s*\[\s*(\d+)\s*@[^\]]*\]\s?(.*)$"#)
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = tag.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let number = Int(line[numberRange]), number >= 1 else {
                untagged += 1
                continue
            }
            let rest = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
            // The same tag twice (a line copied and edited) keeps both.
            if let earlier = kept[number - 1] {
                kept[number - 1] = earlier + " " + rest
            } else {
                kept[number - 1] = rest
            }
        }
        return (kept, untagged)
    }

    // MARK: Matching words

    /// Lower-case letters and digits only, so punctuation and capitalization
    /// changes don't count as deletions.
    static func normalized(_ word: String) -> String {
        word.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// For each original word, whether it survives in `edited`. Uses the
    /// longest common subsequence, so deleting any words keeps the rest
    /// matched in order. Returns the flags and the edited words that match
    /// nothing in the original (typed-in additions).
    static func keptFlags(original: [String], edited: [String]) -> (kept: [Bool], added: [String]) {
        let a = original.map(normalized)
        let b = edited.map(normalized)
        let n = a.count, m = b.count
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var kept = Array(repeating: false, count: n)
        var usedEdited = Array(repeating: false, count: m)
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                kept[i] = true
                usedEdited[j] = true
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // Words that are only punctuation ("—") can't be told apart; keep
        // them whenever both neighbours are kept.
        for k in 0..<n where a[k].isEmpty {
            let before = k == 0 || kept[k - 1]
            let after = k == n - 1 || kept[k + 1]
            kept[k] = before && after
        }
        let added = zip(edited, usedEdited).compactMap { word, used in
            used || normalized(word).isEmpty ? nil : word
        }
        return (kept, added)
    }

    // MARK: Plan

    static func plan(transcript: WordTranscript, editText: String, duration: TimeInterval) -> EditPlan {
        let (keptLines, untagged) = parseEditFile(editText)

        // Every word in the recording, in order, with whether it stays.
        struct Item { var word: TranscriptWord; var segment: Int; var keep: Bool }
        var items: [Item] = []
        var added: [String] = []
        var deletedLines = 0
        for (index, segment) in transcript.segments.enumerated() {
            // A segment Whisper gave no word times for counts as one word.
            let words = segment.words.isEmpty
                ? [TranscriptWord(text: segment.text, start: segment.start, end: segment.end)]
                : segment.words
            guard let text = keptLines[index] else {
                deletedLines += 1
                items += words.map { Item(word: $0, segment: index, keep: false) }
                continue
            }
            let original = segment.words.isEmpty ? tokens(segment.text) : words.map(\.text)
            let result = keptFlags(original: original, edited: tokens(text))
            added += result.added
            if segment.words.isEmpty {
                let keep = result.kept.contains(true)
                items.append(Item(word: words[0], segment: index, keep: keep))
            } else {
                for (word, keep) in zip(words, result.kept) {
                    items.append(Item(word: word, segment: index, keep: keep))
                }
            }
        }

        // Cuts: each run of deleted words, from just after the kept word
        // before it to just before the kept word after it.
        var cuts: [TimeSpan] = []
        var k = 0
        while k < items.count {
            guard !items[k].keep else { k += 1; continue }
            var e = k
            while e + 1 < items.count && !items[e + 1].keep { e += 1 }
            let start = k == 0 ? 0 : min(items[k - 1].word.end + padding, items[k].word.start)
            let end = e == items.count - 1 ? duration : max(items[e + 1].word.start - padding, items[e].word.end)
            if end - start >= minimumCut { cuts.append(TimeSpan(start: max(0, start), end: min(duration, end))) }
            k = e + 1
        }
        let keep = complement(of: cuts, within: duration)

        // The remaining transcript on the edited video's clock.
        var segments: [WordSegment] = []
        for index in transcript.segments.indices {
            let words = items.filter { $0.segment == index && $0.keep }.map(\.word)
            guard !words.isEmpty else { continue }
            let moved = words.map {
                TranscriptWord(text: $0.text, start: editedTime($0.start, keep: keep), end: editedTime($0.end, keep: keep))
            }
            let text = transcript.segments[index].words.isEmpty
                ? transcript.segments[index].text
                : moved.map(\.text).joined(separator: " ")
            segments.append(WordSegment(start: moved.first!.start, end: moved.last!.end, text: text, words: moved))
        }

        var plan = EditPlan(
            keep: keep,
            segments: segments,
            deletedWordCount: items.filter { !$0.keep }.count,
            deletedLineCount: deletedLines,
            ignoredAddedWords: added,
            untaggedLineCount: untagged
        )
        plan.removedSeconds = duration - keep.reduce(0) { $0 + $1.duration }
        return plan
    }

    /// The parts of 0…duration not covered by `cuts` (which may overlap).
    static func complement(of cuts: [TimeSpan], within duration: TimeInterval) -> [TimeSpan] {
        var keep: [TimeSpan] = []
        var cursor: TimeInterval = 0
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if cut.start > cursor { keep.append(TimeSpan(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < duration { keep.append(TimeSpan(start: cursor, end: duration)) }
        return keep.filter { $0.duration > 0.001 }
    }

    /// Where a moment of the original lands in the edited video. A moment
    /// inside a cut maps to where the cut is.
    static func editedTime(_ t: TimeInterval, keep: [TimeSpan]) -> TimeInterval {
        var elapsed: TimeInterval = 0
        for span in keep {
            if t < span.start { return elapsed }
            if t <= span.end { return elapsed + (t - span.start) }
            elapsed += span.duration
        }
        return elapsed
    }

    // MARK: Formatting

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    static func srtText(_ segments: [WordSegment]) -> String {
        func srtTime(_ t: TimeInterval) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return segments.enumerated().map { index, segment in
            "\(index + 1)\n\(srtTime(segment.start)) --> \(srtTime(segment.end))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }
}
