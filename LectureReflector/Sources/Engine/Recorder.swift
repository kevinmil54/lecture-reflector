import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Writes composited video frames + mic audio with hardware H.264 and AAC.
///
/// Crash safety: recording goes to a QuickTime file with 5-second movie
/// fragments, so a crash or power loss loses at most the last few seconds and
/// the partial file stays playable. On stop, the file is remuxed (no
/// re-encode) into the final MP4.
///
/// Pause/resume: while paused, nothing is appended; on resume, the accumulated
/// pause duration is subtracted from every timestamp so the output timeline
/// has no gap.
///
/// All append methods are safe to call from any queue and no-op when idle.
final class Recorder {
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var firstPTS: CMTime?
    private var pausedOffset = CMTime.zero
    private var pauseStartedAt: CMTime?

    var isRecording: Bool {
        lock.withLock { writer != nil }
    }

    var isPaused: Bool {
        lock.withLock { pauseStartedAt != nil }
    }

    /// Seconds of recorded material so far (excludes paused time).
    var elapsedSeconds: Double? {
        lock.withLock {
            guard sessionStarted, let firstPTS else { return nil }
            var now = CMClockGetTime(CMClockGetHostTimeClock())
            if let pauseStartedAt {
                now = pauseStartedAt
            }
            return (now - pausedOffset - firstPTS).seconds
        }
    }

    func start(outputURL: URL, size: CGSize, audioFormatHint: CMFormatDescription?) throws {
        lock.lock()
        defer { lock.unlock() }
        guard writer == nil else { return }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 5, timescale: 1)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 6_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        writer.add(video)

        var channels = 1
        if let hint = audioFormatHint,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(hint)?.pointee {
            channels = max(1, min(2, Int(asbd.mChannelsPerFrame)))
        }
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormatHint)
        audio.expectsMediaDataInRealTime = true
        writer.add(audio)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )

        guard writer.startWriting() else {
            throw writer.error ?? LectureReflectorError("Could not start writing \(outputURL.lastPathComponent)")
        }

        self.writer = writer
        self.videoInput = video
        self.audioInput = audio
        self.adaptor = adaptor
        self.sessionStarted = false
        self.firstPTS = nil
        self.pausedOffset = .zero
        self.pauseStartedAt = nil
    }

    func pause() {
        lock.withLock {
            guard writer != nil, pauseStartedAt == nil else { return }
            pauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    func resume() {
        lock.withLock {
            guard let pauseStart = pauseStartedAt else { return }
            pausedOffset = pausedOffset + (CMClockGetTime(CMClockGetHostTimeClock()) - pauseStart)
            pauseStartedAt = nil
        }
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let writer, let videoInput, let adaptor, pauseStartedAt == nil else { return }
        let adjusted = time - pausedOffset
        if !sessionStarted {
            writer.startSession(atSourceTime: adjusted)
            firstPTS = adjusted
            sessionStarted = true
        }
        if videoInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: adjusted)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard writer != nil, sessionStarted, pauseStartedAt == nil,
              let audioInput, audioInput.isReadyForMoreMediaData else { return }
        if pausedOffset == .zero {
            audioInput.append(sampleBuffer)
        } else if let retimed = Self.retime(sampleBuffer, by: pausedOffset) {
            audioInput.append(retimed)
        }
    }

    func finish() async throws -> URL {
        guard let writer = takeWriter() else {
            throw LectureReflectorError("Not recording")
        }
        let url = writer.outputURL
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        if writer.status == .failed {
            throw writer.error ?? LectureReflectorError("Failed to finalize \(url.lastPathComponent)")
        }
        return url
    }

    /// Remux (no re-encode) the fragmented QuickTime recording into an MP4.
    static func remuxToMP4(from movURL: URL, to mp4URL: URL) async throws {
        try? FileManager.default.removeItem(at: mp4URL)
        let asset = AVURLAsset(url: movURL)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw LectureReflectorError("Could not create the MP4 converter")
        }
        export.outputURL = mp4URL
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? LectureReflectorError("Could not convert the recording to MP4")
        }
    }

    // MARK: - Internals

    /// Detach the current writer under the lock so appends become no-ops.
    private func takeWriter() -> AVAssetWriter? {
        lock.withLock {
            guard let current = writer else { return nil }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer = nil
            videoInput = nil
            audioInput = nil
            adaptor = nil
            sessionStarted = false
            firstPTS = nil
            pauseStartedAt = nil
            pausedOffset = .zero
            return current
        }
    }

    private static func retime(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for index in 0..<count {
            infos[index].presentationTimeStamp = infos[index].presentationTimeStamp - offset
            if infos[index].decodeTimeStamp.isValid {
                infos[index].decodeTimeStamp = infos[index].decodeTimeStamp - offset
            }
        }
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &retimed
        )
        return retimed
    }
}

// MARK: - Automatic level correction

/// Brings a finished recording's audio to a standard loudness (-16 LUFS,
/// the usual target for online video) without touching the video track, and
/// optionally cleans up the voice first.
///
/// Pass 1 measures the raw signal: integrated loudness (ITU-R BS.1770:
/// K-weighting, 400 ms blocks, absolute and relative gating), noise floor in
/// pauses and presence (3–8 kHz against 300–3000 Hz). With cleanup on, pass 2
/// measures loudness again after the cleanup chain, since compression changes
/// it. The last pass runs the chain, applies one fixed gain to the whole file
/// and a peak limiter at -1.5 dBFS (instant attack, 100 ms release) so the
/// boost never clips. Video is copied as-is.
///
/// The cleanup chain, when on: a 24 dB/octave high-pass at 90 Hz (room
/// rumble, handling noise), a +4 dB shelf above 3 kHz (a lav mic that is too
/// far away or off-axis loses highs first) and a gentle 2:1 compressor on the
/// top of the voice, so the loudness comes from its body rather than from the
/// limiter flattening its peaks. The compressor threshold sits 8 dB above the
/// raw loudness, so it does the same job on a quiet recording as on a loud one.
enum AudioLeveler {
    static let targetLUFS = -16.0
    static let maxBoostDB = 24.0
    static let maxCutDB = -12.0
    static let ceiling: Float = 0.841   // -1.5 dBFS sample peak; AAC encoding adds a little overshoot

    static let highPassHz = 90.0
    static let presenceHz = 3_000.0
    static let presenceDB = 4.0
    static let compressAboveLoudnessDB = 8.0
    static let compressRatio = 2.0

    /// Below this 3–8 kHz vs 300–3000 Hz ratio the voice sounds dull.
    static let dullPresenceDB = -12.0
    /// Above this share of limited samples, loudness is being set by peaks.
    static let limiterWarningFraction = 0.05

    private static let pcmSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// Rewrites `url` in place with corrected audio. Returns a report of one
    /// line per finding for audio-check.txt.
    static func normalize(fileAt url: URL, cleanup: Bool) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            return "Level correction: no audio track"
        }
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        var videoFormat: CMFormatDescription?
        var transform = CGAffineTransform.identity
        if let videoTrack {
            videoFormat = try await videoTrack.load(.formatDescriptions).first
            transform = try await videoTrack.load(.preferredTransform)
        }
        let vFormat = videoFormat
        let vTransform = transform

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let raw = try measure(asset: asset, track: audioTrack, chain: nil)
                    var lines = [String]()
                    lines.append(String(format: "Noise floor in pauses: %.0f dBFS", raw.noiseFloorDB))
                    var presence = String(format: "Presence (3–8 kHz vs 300–3000 Hz): %+.0f dB", raw.presenceDB)
                    if raw.presenceDB < dullPresenceDB {
                        presence += " — voice sounds dull; move the mic closer or point it at your mouth"
                    }
                    lines.append(presence)

                    guard let rawLoudness = raw.loudness else {
                        lines.append("Voice cleanup: skipped (no speech found)")
                        lines.append("Level correction: skipped (no speech found)")
                        continuation.resume(returning: lines.joined(separator: "\n"))
                        return
                    }
                    var chain: Cleanup?
                    var loudness = rawLoudness
                    if cleanup {
                        let threshold = rawLoudness + compressAboveLoudnessDB
                        chain = Cleanup(compressThresholdDB: threshold)
                        lines.append(String(
                            format: "Voice cleanup: high-pass %.0f Hz, presence %+.0f dB above %.0f kHz, %.0f:1 compression above %.0f dBFS",
                            highPassHz, presenceDB, presenceHz / 1000, compressRatio, threshold))
                        loudness = try measure(asset: asset, track: audioTrack, chain: chain).loudness ?? rawLoudness
                    } else {
                        lines.append("Voice cleanup: off")
                    }
                    let gainDB = min(maxBoostDB, max(maxCutDB, targetLUFS - loudness))
                    if abs(gainDB) < 0.5 && !cleanup {
                        lines.append(String(format: "Level correction: not needed (measured %.1f LUFS)", loudness))
                        continuation.resume(returning: lines.joined(separator: "\n"))
                        return
                    }
                    let temp = url.deletingLastPathComponent().appendingPathComponent("lecture-leveling.mp4")
                    let limited = try rewrite(asset: asset, audioTrack: audioTrack, videoTrack: videoTrack,
                                              videoFormat: vFormat, transform: vTransform,
                                              gain: Float(pow(10, gainDB / 20)), chain: chain, to: temp)
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                    lines.append(String(
                        format: "Level correction: measured %.1f LUFS, applied %+.1f dB (target %.0f LUFS); limiter active on %.2f%% of samples",
                        loudness, gainDB, targetLUFS, limited * 100))
                    if limited > limiterWarningFraction {
                        lines.append(String(format: "Warning: the limiter was active on %.0f%% of the recording, so the level is being set by peaks. Move the mic closer or speak more evenly.", limited * 100))
                    }
                    continuation.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appendingPathComponent("lecture-leveling.mp4"))
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Filters

    private struct Biquad {
        var b0, b1, b2, a1, a2: Double
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        init(_ b0: Double, _ b1: Double, _ b2: Double, _ a1: Double, _ a2: Double) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
        }
        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }

        // Audio EQ Cookbook (R. Bristow-Johnson) designs at 48 kHz, Q = 1/√2.
        private static let sampleRate = 48_000.0

        static func highPass(_ hz: Double) -> Biquad {
            let w0 = 2 * Double.pi * hz / sampleRate
            let alpha = sin(w0) / (2 * 0.7071)
            let a0 = 1 + alpha
            return Biquad((1 + cos(w0)) / 2 / a0, -(1 + cos(w0)) / a0, (1 + cos(w0)) / 2 / a0,
                          -2 * cos(w0) / a0, (1 - alpha) / a0)
        }

        static func lowPass(_ hz: Double) -> Biquad {
            let w0 = 2 * Double.pi * hz / sampleRate
            let alpha = sin(w0) / (2 * 0.7071)
            let a0 = 1 + alpha
            return Biquad((1 - cos(w0)) / 2 / a0, (1 - cos(w0)) / a0, (1 - cos(w0)) / 2 / a0,
                          -2 * cos(w0) / a0, (1 - alpha) / a0)
        }

        static func highShelf(_ hz: Double, gainDB: Double) -> Biquad {
            let A = pow(10, gainDB / 40)
            let w0 = 2 * Double.pi * hz / sampleRate
            let alpha = sin(w0) / 2 * sqrt((A + 1 / A) * (1 / 0.7071 - 1) + 2)
            let c = cos(w0)
            let a0 = (A + 1) - (A - 1) * c + 2 * sqrt(A) * alpha
            return Biquad(A * ((A + 1) + (A - 1) * c + 2 * sqrt(A) * alpha) / a0,
                          -2 * A * ((A - 1) + (A + 1) * c) / a0,
                          A * ((A + 1) + (A - 1) * c - 2 * sqrt(A) * alpha) / a0,
                          2 * ((A - 1) - (A + 1) * c) / a0,
                          ((A + 1) - (A - 1) * c - 2 * sqrt(A) * alpha) / a0)
        }
    }

    /// Feed-forward peak compressor: 2 ms attack with a matching 2 ms
    /// look-ahead (the gain is applied to a delayed copy, so the start of a
    /// loud syllable is caught rather than let through), 150 ms release.
    /// Make-up gain is not applied here; the loudness pass measures the
    /// compressed signal and the level correction supplies it.
    private struct Compressor {
        private let thresholdDB: Double
        private let slope: Double   // 1 - 1/ratio
        private let attack = 1 - exp(-1.0 / (0.002 * 48_000))
        private let release = 1 - exp(-1.0 / (0.150 * 48_000))
        private var envelope = 0.0
        private var delay = [Double](repeating: 0, count: 96)   // 2 ms at 48 kHz
        private var delayIndex = 0

        init(thresholdDB: Double, ratio: Double) {
            self.thresholdDB = thresholdDB
            self.slope = 1 - 1 / ratio
        }

        mutating func process(_ x: Double) -> Double {
            let level = abs(x)
            envelope += (level > envelope ? attack : release) * (level - envelope)
            let delayed = delay[delayIndex]
            delay[delayIndex] = x
            delayIndex = (delayIndex + 1) % delay.count
            let overDB = 20 * log10(max(envelope, 1e-9)) - thresholdDB
            guard overDB > 0 else { return delayed }
            return delayed * pow(10, -overDB * slope / 20)
        }
    }

    /// The voice-cleanup chain, applied sample by sample. A fresh copy is
    /// used for each pass so the filters start from rest.
    private struct Cleanup {
        // Two cascaded 2nd-order Butterworth sections: 24 dB/octave.
        private var rumble1 = Biquad.highPass(highPassHz)
        private var rumble2 = Biquad.highPass(highPassHz)
        private var presence = Biquad.highShelf(presenceHz, gainDB: presenceDB)
        private var compressor: Compressor

        init(compressThresholdDB: Double) {
            compressor = Compressor(thresholdDB: compressThresholdDB, ratio: compressRatio)
        }

        mutating func process(_ x: Double) -> Double {
            compressor.process(presence.process(rumble2.process(rumble1.process(x))))
        }
    }

    // MARK: Pass 1 — measure

    private struct Measurement {
        /// Integrated loudness after `chain`, if any; nil when nothing passed
        /// the gates, i.e. no speech.
        var loudness: Double?
        /// 10th percentile of 100 ms blocks of the raw signal, dBFS.
        var noiseFloorDB: Double
        /// 3–8 kHz RMS relative to 300–3000 Hz RMS in the raw signal, dB.
        var presenceDB: Double
    }

    private static func measure(asset: AVAsset, track: AVAssetTrack, chain: Cleanup?) throws -> Measurement {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? LectureReflectorError("Could not read the recording's audio")
        }
        // BS.1770 K-weighting coefficients for 48 kHz.
        var shelf = Biquad(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)
        var highPass = Biquad(1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)
        var chain = chain
        // Raw-signal analysis: the two presence bands and 100 ms block power.
        var midHigh = Biquad.highPass(300), midLow = Biquad.lowPass(3_000)
        var topHigh = Biquad.highPass(3_000), topLow = Biquad.lowPass(8_000)
        var midPower = 0.0, topPower = 0.0
        var rawBlocks: [Double] = []
        var rawAcc = 0.0
        let subLength = 4_800   // 100 ms
        var subBlocks: [Double] = []
        var acc = 0.0
        var accCount = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            for v in floats(sampleBuffer) {
                let x = Double(v)
                let mid = midLow.process(midHigh.process(x))
                let top = topLow.process(topHigh.process(x))
                midPower += mid * mid
                topPower += top * top
                rawAcc += x * x
                let cleaned = chain?.process(x) ?? x
                let y = highPass.process(shelf.process(cleaned))
                acc += y * y
                accCount += 1
                if accCount == subLength {
                    subBlocks.append(acc / Double(subLength))
                    rawBlocks.append(rawAcc / Double(subLength))
                    acc = 0
                    rawAcc = 0
                    accCount = 0
                }
            }
        }
        if reader.status == .failed {
            throw reader.error ?? LectureReflectorError("Could not read the recording's audio")
        }
        func dB(_ meanSquare: Double) -> Double { 10 * log10(max(meanSquare, 1e-20)) }
        let sortedRaw = rawBlocks.sorted()
        let noiseFloorDB = sortedRaw.isEmpty ? -160 : dB(sortedRaw[sortedRaw.count / 10])
        let presenceDB = dB(topPower) - dB(midPower)
        var result = Measurement(loudness: nil, noiseFloorDB: noiseFloorDB, presenceDB: presenceDB)

        guard subBlocks.count >= 4 else { return result }
        var blocks: [Double] = []
        for i in 0...(subBlocks.count - 4) {
            blocks.append((subBlocks[i] + subBlocks[i + 1] + subBlocks[i + 2] + subBlocks[i + 3]) / 4)
        }
        func lufs(_ meanSquare: Double) -> Double { -0.691 + dB(meanSquare) }
        let aboveAbsolute = blocks.filter { lufs($0) > -70 }
        guard !aboveAbsolute.isEmpty else { return result }
        let relativeGate = lufs(aboveAbsolute.reduce(0, +) / Double(aboveAbsolute.count)) - 10
        let gated = aboveAbsolute.filter { lufs($0) > relativeGate }
        guard !gated.isEmpty else { return result }
        result.loudness = lufs(gated.reduce(0, +) / Double(gated.count))
        return result
    }

    // MARK: Pass 2 — rewrite

    /// Returns the fraction of samples where the limiter reduced gain by more
    /// than 0.5 dB.
    private static func rewrite(asset: AVAsset, audioTrack: AVAssetTrack, videoTrack: AVAssetTrack?,
                                videoFormat: CMFormatDescription?, transform: CGAffineTransform,
                                gain: Float, chain: Cleanup?, to outURL: URL) throws -> Double {
        try? FileManager.default.removeItem(at: outURL)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var videoOut: AVAssetReaderTrackOutput?
        var videoIn: AVAssetWriterInput?
        if let videoTrack {
            let out = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            videoOut = out
            videoIn = input
        }

        let audioOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
        reader.add(audioOut)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 160_000,
        ])
        audioIn.expectsMediaDataInRealTime = false
        writer.add(audioIn)

        guard reader.startReading() else {
            throw reader.error ?? LectureReflectorError("Could not read the recording")
        }
        guard writer.startWriting() else {
            throw writer.error ?? LectureReflectorError("Could not write the level-corrected file")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        var failure: Error?
        let failureLock = NSLock()
        func fail(_ error: Error?) {
            failureLock.withLock { if failure == nil { failure = error ?? LectureReflectorError("Writing failed") } }
        }

        if let videoOut, let videoIn {
            group.enter()
            var done = false
            videoIn.requestMediaDataWhenReady(on: DispatchQueue(label: "lecture_reflector.level.video")) {
                while !done && videoIn.isReadyForMoreMediaData {
                    if let sampleBuffer = videoOut.copyNextSampleBuffer() {
                        if !videoIn.append(sampleBuffer) { fail(writer.error); done = true }
                    } else {
                        done = true
                    }
                    if done {
                        videoIn.markAsFinished()
                        group.leave()
                    }
                }
            }
        }

        var envelope: Float = 1
        let release = Float(1 - exp(-1.0 / (0.1 * 48_000)))
        var chain = chain
        var limitedCount = 0
        var totalCount = 0
        group.enter()
        var audioDone = false
        audioIn.requestMediaDataWhenReady(on: DispatchQueue(label: "lecture_reflector.level.audio")) {
            while !audioDone && audioIn.isReadyForMoreMediaData {
                if let sampleBuffer = audioOut.copyNextSampleBuffer() {
                    var samples = floats(sampleBuffer)
                    for i in samples.indices {
                        let x = chain != nil ? Float(chain!.process(Double(samples[i]))) : samples[i]
                        let y = x * gain
                        let a = abs(y)
                        let needed: Float = a > ceiling ? ceiling / a : 1
                        if needed < envelope {
                            envelope = needed
                        } else {
                            envelope += (needed - envelope) * release
                        }
                        if envelope < 0.944 { limitedCount += 1 }   // more than 0.5 dB of reduction
                        samples[i] = y * envelope
                    }
                    totalCount += samples.count
                    if let processed = makeBuffer(samples, like: sampleBuffer) {
                        if !audioIn.append(processed) { fail(writer.error); audioDone = true }
                    } else {
                        fail(LectureReflectorError("Could not build an audio buffer"))
                        audioDone = true
                    }
                } else {
                    audioDone = true
                }
                if audioDone {
                    audioIn.markAsFinished()
                    group.leave()
                }
            }
        }

        group.wait()
        if reader.status == .failed { fail(reader.error) }
        if let failure = failureLock.withLock({ failure }) {
            reader.cancelReading()
            writer.cancelWriting()
            throw failure
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard writer.status == .completed else {
            throw writer.error ?? LectureReflectorError("Could not finish the level-corrected file")
        }
        return totalCount > 0 ? Double(limitedCount) / Double(totalCount) : 0
    }

    // MARK: Buffers

    private static func floats(_ sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        values.withUnsafeMutableBytes { raw in
            if let base = raw.baseAddress {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: base)
            }
        }
        return values
    }

    private static func makeBuffer(_ samples: [Float], like original: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(original), !samples.isEmpty else { return nil }
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { return nil }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: samples.count, presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(original),
            packetDescriptions: nil, sampleBufferOut: &out) == noErr else { return nil }
        return out
    }
}
