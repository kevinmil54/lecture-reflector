import Foundation

// Correcting a transcript and a deck's speaker notes from the deck itself.
//
// The lecturer picks the Quarto source (.qmd) of the deck. Lecture Reflector
// reads its slide text, speaker notes and distinctive terms, and asks a local
// model running in Ollama (nothing leaves the Mac) to fix what Whisper most
// likely misheard: names, technical terms and spellings the deck shows.
//
// Files written to the recording folder:
//   lecture-raw.txt / lecture-raw.srt / lecture-words-raw.json   Whisper's output, untouched
//   lecture.txt / lecture.srt / lecture-words.json / lecture-edit.txt   corrected
//   <deck name>-corrected.qmd   copy of the deck with corrected speaker notes
//   corrections.txt             every change, as "heard → corrected"
// The deck itself is never modified.

// MARK: Deck

struct SpeakerNotes {
    /// Line indexes (into the deck's lines) of the notes body.
    var bodyRange: Range<Int>
    var text: String
}

struct DeckContext {
    var title: String
    var lines: [String]
    var notes: [SpeakerNotes]
    /// Slide text and notes, split at blank lines, in reading order.
    var paragraphs: [String]
    /// Distinctive words (names, acronyms, terms), most frequent first.
    var terms: [String]

    static func load(from url: URL) throws -> DeckContext {
        let source = try String(contentsOf: url, encoding: .utf8)
        return DeckContext(source: source)
    }

    init(source: String) {
        let lines = source.components(separatedBy: "\n")
        var title = ""
        var start = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                if title.isEmpty, lines[i].hasPrefix("title:") {
                    title = lines[i].dropFirst(6).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
                i += 1
            }
            start = min(i + 1, lines.count)
        }

        var notes: [SpeakerNotes] = []
        var paragraphs: [String] = []
        var current: [String] = []
        var inCode = false
        var depth = 0
        var notesDepth: Int?
        var notesStart = 0
        var notesLines: [String] = []

        func flush(_ block: inout [String]) {
            let text = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { paragraphs.append(text) }
            block = []
        }

        var i = start
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                if notesDepth != nil { notesLines.append(line) }
                continue
            }
            if inCode {
                if notesDepth != nil { notesLines.append(line) }
                continue
            }
            if trimmed.hasPrefix(":::") {
                let rest = trimmed.drop(while: { $0 == ":" }).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    if let level = notesDepth, depth == level {
                        let text = notesLines.joined(separator: "\n")
                        notes.append(SpeakerNotes(bodyRange: notesStart..<i, text: text))
                        flush(&current)
                        var block: [String] = []
                        for noteLine in notesLines {
                            if noteLine.trimmingCharacters(in: .whitespaces).isEmpty { flush(&block) } else { block.append(noteLine) }
                        }
                        flush(&block)
                        notesDepth = nil
                        notesLines = []
                    } else if notesDepth != nil {
                        notesLines.append(line)
                    }
                    depth -= 1
                } else {
                    depth += 1
                    if notesDepth == nil {
                        if rest == "notes" || rest.contains(".notes") {
                            notesDepth = depth
                            notesStart = i + 1
                            notesLines = []
                        }
                    } else {
                        notesLines.append(line)
                    }
                }
                continue
            }
            if notesDepth != nil {
                notesLines.append(line)
            } else if trimmed.isEmpty {
                flush(&current)
            } else {
                current.append(line)
            }
        }
        flush(&current)

        self.title = title
        self.lines = lines
        self.notes = notes
        self.paragraphs = paragraphs
        self.terms = Self.distinctiveTerms(in: paragraphs.joined(separator: "\n\n"))
    }

    /// Capitalized words, acronyms and words with inner capitals, minus ordinary
    /// words that only look capitalized because they start a sentence.
    static func distinctiveTerms(in text: String) -> [String] {
        let lowercased = Set(
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.first?.isLowercase == true }
                .map { String($0) }
        )
        var counts: [String: Int] = [:]
        for pattern in ["\\b[A-Z][A-Za-z0-9'’\\-]{2,}\\b", "\\b[a-z]+[A-Z][A-Za-z0-9]*\\b"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                let word = String(text[r])
                if lowercased.contains(word.lowercased()) { continue }
                counts[word, default: 0] += 1
            }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(120)
            .map(\.key)
    }

    static func contentWords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0) }
            .filter { $0.count >= 4 })
    }

    /// The deck paragraphs that share the most words with `text`, in deck
    /// order, up to `limit` characters.
    func excerpt(for text: String, limit: Int) -> String {
        let words = Self.contentWords(text)
        var scored: [(index: Int, score: Double)] = []
        for (index, paragraph) in paragraphs.enumerated() {
            let paragraphWords = Self.contentWords(paragraph)
            guard !paragraphWords.isEmpty else { continue }
            let overlap = paragraphWords.intersection(words).count
            if overlap > 0 {
                scored.append((index, Double(overlap) / Double(paragraphWords.count).squareRoot()))
            }
        }
        scored.sort { $0.score > $1.score }
        var chosen: [Int] = []
        var used = 0
        for item in scored {
            let length = paragraphs[item.index].count
            if used + length > limit { continue }
            chosen.append(item.index)
            used += length
        }
        return chosen.sorted().map { paragraphs[$0] }.joined(separator: "\n\n")
    }

    /// The deck's text with the speaker notes at the given indexes replaced.
    func replacingNotes(_ corrected: [Int: String]) -> String {
        var out = lines
        for (index, block) in notes.enumerated().reversed() {
            guard let text = corrected[index] else { continue }
            out.replaceSubrange(block.bodyRange, with: text.components(separatedBy: "\n"))
        }
        return out.joined(separator: "\n")
    }
}

// MARK: Ollama

struct OllamaClient {
    /// An IP address rather than "localhost" so App Transport Security allows plain HTTP.
    var baseURL = URL(string: "http://127.0.0.1:11434")!
    var model: String

    /// Names of the models installed in Ollama, or nil if Ollama isn't running.
    func installedModels() async -> [String]? {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["name"] as? String }
    }

    func chat(system: String, user: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0, "num_ctx": 8192],
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw LectureReflectorError("Ollama returned an error. \(detail.prefix(200))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LectureReflectorError("Ollama's reply could not be read")
        }
        return content
    }
}

// MARK: Correction

struct CorrectionOutcome {
    var segments: [TranscriptSegment]
    var summary: String
}

enum ContentCorrector {
    static let defaultModel = "qwen2.5:7b"
    static let linesPerRequest = 20
    /// Largest share of a line's words a correction may change before it is
    /// treated as a rewrite and refused.
    static let maxChangedInLine = 0.5
    static let maxChangedInNotes = 0.25

    /// Corrects `segments` and the deck's speaker notes, writes the report
    /// and the corrected deck copy to `folder`, and returns the new segments.
    /// Throws (leaving `segments` usable by the caller) if the deck can't be
    /// read or Ollama isn't available.
    static func apply(deckURL: URL, model: String, to segments: [TranscriptSegment],
                      folder: URL, progress: @escaping (String) -> Void) async throws -> CorrectionOutcome {
        let deck: DeckContext
        do {
            deck = try DeckContext.load(from: deckURL)
        } catch {
            throw LectureReflectorError("Could not read the deck “\(deckURL.lastPathComponent)”: \(error.localizedDescription)")
        }
        let model = model.trimmingCharacters(in: .whitespaces).isEmpty ? defaultModel : model.trimmingCharacters(in: .whitespaces)
        let client = OllamaClient(model: model)
        guard let installed = await client.installedModels() else {
            throw LectureReflectorError("Ollama is not running. Start the Ollama app, then correct the recording from the deck.")
        }
        guard installed.contains(where: { $0 == model || $0 == model + ":latest" }) else {
            throw LectureReflectorError("The model “\(model)” is not installed in Ollama. In Terminal, run: ollama pull \(model)")
        }

        var report = ["Corrections from \(deckURL.lastPathComponent) using \(model)", ""]

        // Transcript
        var corrected = segments
        var changedLines = 0
        var refusedLines = 0
        var failedChunks = 0
        report.append("TRANSCRIPT (heard → corrected)")
        let chunkCount = (segments.count + linesPerRequest - 1) / linesPerRequest
        for chunk in 0..<chunkCount {
            progress("Correcting the transcript from the deck (\(chunk + 1) of \(chunkCount))…")
            let range = (chunk * linesPerRequest)..<min(segments.count, (chunk + 1) * linesPerRequest)
            let lines = range.map { segments[$0].text }
            let results = await correctedLines(lines, deck: deck, client: client)
            if results.allSatisfy({ $0 == nil }) {
                failedChunks += 1
                if failedChunks >= 2 {
                    throw LectureReflectorError("Ollama stopped answering, so the rest of the transcript was left as Whisper heard it.")
                }
            }
            for (offset, result) in results.enumerated() {
                let index = range.lowerBound + offset
                guard let result else { refusedLines += 1; continue }
                let new = result.trimmingCharacters(in: .whitespacesAndNewlines)
                let old = segments[index].text
                if new == old { continue }
                guard acceptable(old: old, new: new, limit: maxChangedInLine) else { refusedLines += 1; continue }
                let segment = segments[index]
                corrected[index] = TranscriptSegment(
                    start: segment.start, end: segment.end, text: new,
                    words: remap(words: segment.words, newText: new, start: segment.start, end: segment.end)
                )
                changedLines += 1
                for (heard, fixed) in wordChanges(from: old, to: new) {
                    report.append("[\(index + 1) @ \(hms(segment.start))] \(heard.isEmpty ? "(nothing)" : heard) → \(fixed.isEmpty ? "(removed)" : fixed)")
                }
            }
        }
        if changedLines == 0 { report.append("No changes.") }

        // Speaker notes
        report.append("")
        report.append("SPEAKER NOTES (before → after)")
        var notesCorrected: [Int: String] = [:]
        var refusedNotes = 0
        for (index, block) in deck.notes.enumerated() {
            guard !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            progress("Correcting speaker notes (\(index + 1) of \(deck.notes.count))…")
            guard let new = try? await correctedNotes(block.text, deck: deck, client: client) else { refusedNotes += 1; continue }
            if new == block.text { continue }
            let sameShape = new.components(separatedBy: "\n").count == block.text.components(separatedBy: "\n").count
            guard sameShape, acceptable(old: block.text, new: new, limit: maxChangedInNotes) else { refusedNotes += 1; continue }
            notesCorrected[index] = new
            for (before, after) in wordChanges(from: block.text, to: new) {
                report.append("[notes \(index + 1)] \(before.isEmpty ? "(nothing)" : before) → \(after.isEmpty ? "(removed)" : after)")
            }
        }
        if notesCorrected.isEmpty { report.append("No changes.") }
        if refusedLines + refusedNotes > 0 {
            report.append("")
            report.append("Left as they were because the model's answer was unusable or rewrote too much: \(refusedLines) transcript line(s), \(refusedNotes) notes passage(s).")
        }

        try? report.joined(separator: "\n")
            .write(to: folder.appendingPathComponent("corrections.txt"), atomically: true, encoding: .utf8)
        if !notesCorrected.isEmpty {
            let stem = deckURL.deletingPathExtension().lastPathComponent
            let copy = folder.appendingPathComponent("\(stem)-corrected.\(deckURL.pathExtension.isEmpty ? "qmd" : deckURL.pathExtension)")
            try? deck.replacingNotes(notesCorrected).write(to: copy, atomically: true, encoding: .utf8)
        }

        var parts = ["Corrected \(changedLines) transcript line\(changedLines == 1 ? "" : "s")"]
        parts.append("\(notesCorrected.count) speaker-notes passage\(notesCorrected.count == 1 ? "" : "s")")
        return CorrectionOutcome(
            segments: corrected,
            summary: parts.joined(separator: " and ") + ". Changes are listed in corrections.txt; Whisper's original is in lecture-raw.txt."
        )
    }

    // MARK: Model requests

    private static let linesSystemPrompt = """
    You correct speech-recognition errors in a lecture transcript. You get reference material from the lecturer's own slides and speaker notes, a list of key terms from the deck, and a JSON array of transcript lines.

    Change a word only when the recognizer probably misheard a name, technical term, title or spelling that the reference material shows. Do not rephrase, reorder, add, remove or summarize anything. Keep filler words and repetitions. Keep the lecturer's punctuation unless a corrected term needs different capitalization.

    Reply with JSON only, in the form {"lines": [...]}, with exactly one string for each input line, in the same order. A line that needs no change is returned exactly as given.
    """

    private static let notesSystemPrompt = """
    You proofread a lecturer's speaker notes. You get reference material from the same deck and a list of key terms. Fix typos and misspellings, and make names and technical terms spelled the same way as in the reference material. Do not rephrase, reorder, add or remove content. Keep the Markdown (lists, links, emphasis, citations) and the line breaks exactly as they are.

    Reply with JSON only, in the form {"notes": "..."} where the value is the full corrected text with the same number of lines.
    """

    /// One corrected string per input line, or nil for a line whose answer
    /// could not be used. A chunk whose answer has the wrong shape is split
    /// in half and asked again, down to single lines.
    private static func correctedLines(_ lines: [String], deck: DeckContext, client: OllamaClient) async -> [String?] {
        guard !lines.isEmpty else { return [] }
        if let result = try? await requestLines(lines, deck: deck, client: client), result.count == lines.count {
            return result.map { Optional($0) }
        }
        if lines.count == 1 { return [nil] }
        let middle = lines.count / 2
        let first = await correctedLines(Array(lines[..<middle]), deck: deck, client: client)
        let second = await correctedLines(Array(lines[middle...]), deck: deck, client: client)
        return first + second
    }

    private static func requestLines(_ lines: [String], deck: DeckContext, client: OllamaClient) async throws -> [String] {
        let data = try JSONSerialization.data(withJSONObject: lines, options: [.withoutEscapingSlashes])
        let json = String(data: data, encoding: .utf8) ?? "[]"
        let reference = deck.excerpt(for: lines.joined(separator: " "), limit: 2500)
        let user = """
        Lecture title: \(deck.title.isEmpty ? "(untitled)" : deck.title)

        Reference material from the deck:
        \(reference.isEmpty ? "(nothing matched these lines)" : reference)

        Key terms from the deck: \(deck.terms.joined(separator: ", "))

        Transcript lines (JSON array of \(lines.count) strings):
        \(json)
        """
        let reply = try await client.chat(system: linesSystemPrompt, user: user)
        guard let replyData = reply.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
              let result = object["lines"] as? [String] else {
            throw LectureReflectorError("Unreadable answer")
        }
        return result
    }

    private static func correctedNotes(_ text: String, deck: DeckContext, client: OllamaClient) async throws -> String {
        let reference = deck.excerpt(for: text, limit: 2500)
        let user = """
        Lecture title: \(deck.title.isEmpty ? "(untitled)" : deck.title)

        Reference material from the deck:
        \(reference)

        Key terms from the deck: \(deck.terms.joined(separator: ", "))

        Speaker notes to proofread:
        \(text)
        """
        let reply = try await client.chat(system: notesSystemPrompt, user: user)
        guard let replyData = reply.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: replyData) as? [String: Any],
              let result = object["notes"] as? String else {
            throw LectureReflectorError("Unreadable answer")
        }
        return result
    }

    // MARK: Word alignment

    private static func key(_ token: String) -> String {
        let stripped = token.lowercased().filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty ? token : stripped
    }

    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
    }

    /// Pairs of matching positions (longest common subsequence).
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                pairs.append((i, j)); i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    /// Whether `new` is a correction of `old` rather than a rewrite.
    static func acceptable(old: String, new: String, limit: Double) -> Bool {
        let a = tokens(old).map(key), b = tokens(new).map(key)
        guard !b.isEmpty, !a.isEmpty else { return false }
        let kept = Double(align(a, b).count)
        return 1 - kept / Double(max(a.count, b.count)) <= limit
    }

    /// The stretches that differ, as (old words, new words).
    static func wordChanges(from old: String, to new: String) -> [(String, String)] {
        let a = tokens(old), b = tokens(new)
        let pairs = align(a.map(key), b.map(key)) + [(a.count, b.count)]
        var changes: [(String, String)] = []
        var oi = 0, ni = 0
        for (ao, an) in pairs {
            if oi < ao || ni < an {
                changes.append((a[oi..<ao].joined(separator: " "), b[ni..<an].joined(separator: " ")))
            }
            oi = ao + 1
            ni = an + 1
        }
        return changes
    }

    /// Gives the corrected text word timing: unchanged words keep theirs, a
    /// word replaced by one word takes the old word's, and any other changed
    /// stretch shares the old stretch's time in proportion to word length.
    static func remap(words: [TranscriptWord], newText: String, start: TimeInterval, end: TimeInterval) -> [TranscriptWord] {
        guard !words.isEmpty else { return [] }
        let newTokens = tokens(newText)
        guard !newTokens.isEmpty else { return words }
        let anchors = align(words.map { key($0.text) }, newTokens.map(key)) + [(words.count, newTokens.count)]
        var result: [TranscriptWord] = []
        var oi = 0, ni = 0
        var previousEnd = words[0].start
        for (ao, an) in anchors {
            if ni < an {
                let oldGap = oi..<ao
                let newGap = ni..<an
                if oldGap.count == newGap.count {
                    for (o, n) in zip(oldGap, newGap) {
                        result.append(TranscriptWord(text: newTokens[n], start: words[o].start, end: words[o].end))
                    }
                } else {
                    let spanStart = oldGap.isEmpty ? previousEnd : words[oldGap.lowerBound].start
                    let spanEnd = oldGap.isEmpty
                        ? (ao < words.count ? words[ao].start : max(previousEnd, end))
                        : words[oldGap.upperBound - 1].end
                    let total = newGap.reduce(0) { $0 + max(1, newTokens[$1].count) }
                    let duration = max(0, spanEnd - spanStart)
                    var t = spanStart
                    for n in newGap {
                        let share = duration * Double(max(1, newTokens[n].count)) / Double(total)
                        result.append(TranscriptWord(text: newTokens[n], start: t, end: t + share))
                        t += share
                    }
                }
                previousEnd = result.last?.end ?? previousEnd
            }
            if ao < words.count {
                result.append(TranscriptWord(text: newTokens[an], start: words[ao].start, end: words[ao].end))
                previousEnd = words[ao].end
            }
            oi = ao + 1
            ni = an + 1
        }
        return result
    }

    static func hms(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let minutes = (Int(time) / 60) % 60
        let hours = Int(time) / 3600
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
