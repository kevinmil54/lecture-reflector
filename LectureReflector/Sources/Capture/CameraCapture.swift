import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

/// Captures the lecturer's webcam and microphone. Video frames are held as
/// `latestPixelBuffer` for the compositor's 30 fps clock; audio sample buffers
/// are forwarded straight to the recorder (they carry their own timestamps).
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let videoQueue = DispatchQueue(label: "lecture_reflector.camera.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "lecture_reflector.camera.audio", qos: .userInitiated)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private let lock = NSLock()
    private var _latest: CVPixelBuffer?
    private var _audioFormat: CMFormatDescription?

    /// Called on the audio queue for every mic sample buffer.
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Called on the audio queue (throttled to ~10 Hz) with the mic level in dBFS.
    var onAudioLevel: ((Float) -> Void)?
    private var lastLevelSentAt: CFTimeInterval = 0

    var latestPixelBuffer: CVPixelBuffer? {
        lock.withLock { _latest }
    }

    var latestAudioFormat: CMFormatDescription? {
        lock.withLock { _audioFormat }
    }

    static var videoDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static var audioDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    func start(camera: AVCaptureDevice, microphone: AVCaptureDevice?) throws {
        stop()
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            throw LectureReflectorError("Cannot open camera \(camera.localizedName)")
        }
        session.addInput(cameraInput)

        if let microphone {
            let micInput = try AVCaptureDeviceInput(device: microphone)
            if session.canAddInput(micInput) {
                session.addInput(micInput)
            }
        }

        let video = AVCaptureVideoDataOutput()
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(video) else {
            session.commitConfiguration()
            throw LectureReflectorError("Cannot read video from \(camera.localizedName)")
        }
        session.addOutput(video)
        videoOutput = video

        let audio = AVCaptureAudioDataOutput()
        // Ask Core Audio for 32-bit float mono at 48 kHz whatever the mic's
        // native format (the Sennheiser Profile, for one, is 24-bit integer).
        // The recorder and the audio check then always get the same layout.
        audio.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        audio.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audio) {
            session.addOutput(audio)
        }
        audioOutput = audio

        session.commitConfiguration()
        videoQueue.async { [session] in
            session.startRunning()
        }
    }

    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
        lock.withLock {
            _latest = nil
            _audioFormat = nil
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lock.withLock { _latest = pixelBuffer }
        } else if output === audioOutput {
            if latestAudioFormat == nil, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
                lock.withLock { _audioFormat = format }
            }
            onAudioSampleBuffer?(sampleBuffer)
            let now = CACurrentMediaTime()
            if now - lastLevelSentAt > 0.1, let level = connection.audioChannels.first?.averagePowerLevel {
                lastLevelSentAt = now
                onAudioLevel?(level)
            }
        }
    }
}

// MARK: - Audio check

/// What the microphone signal looks like over the last few seconds.
enum AudioStatus: String {
    case waiting = "Waiting for audio"
    case good = "Good"
    case low = "Low — speak to test, or raise input volume"
    case clipping = "Clipping — lower input volume"
    case noise = "Static or heavy noise — check mic and input volume"
    case silent = "No signal — check microphone"
    case unreadable = "Can't analyze this mic's format"

    var isProblem: Bool {
        switch self {
        case .clipping, .noise, .silent: return true
        default: return false
        }
    }
}

struct AudioQuality: Equatable {
    var status: AudioStatus = .waiting
    /// Loudest 50 ms window in the last few seconds (dBFS).
    var speechLevel: Float = -160
    /// Quiet floor: 10th percentile of 50 ms windows (dBFS). Speech with
    /// pauses sits far below -40; static stays high even between words.
    var floor: Float = -160
    var peak: Float = -160
}

/// Analyzes mic sample buffers on the audio queue. It never alters what is
/// recorded. Besides the live status, it totals how long each problem lasted
/// while recording, for the audio-check.txt written next to the video.
final class AudioMonitor {
    var onQuality: ((AudioQuality) -> Void)?

    private let lock = NSLock()
    private var windowSumSq: Double = 0
    private var windowCount = 0
    private var windowPeak: Float = 0
    private var windowLength = 2400
    private var windows: [(rms: Float, peak: Float)] = []   // last ~6 s of 50 ms windows
    private var clippedSamples = 0
    private var totalSamples = 0
    private var lastReport: CFTimeInterval = 0
    private var current = AudioQuality()
    private var formatText = "unknown"

    // Recording summary (seconds per status), guarded by lock.
    private var counting = false
    private var secondsByStatus: [AudioStatus: Double] = [:]

    func beginSummary() {
        lock.withLock {
            counting = true
            secondsByStatus = [:]
            formatText = "unknown"
        }
    }

    /// Stops counting and returns a plain-text report plus whether a problem
    /// covered enough of the recording to warn about.
    func endSummary() -> (text: String, warning: String?) {
        lock.withLock {
            counting = false
            let total = secondsByStatus.values.reduce(0, +)
            func pct(_ s: AudioStatus) -> Double { total > 0 ? (secondsByStatus[s] ?? 0) / total * 100 : 0 }
            var lines = ["Lecture Reflector audio check", "Input format: \(formatText)",
                         String(format: "Analyzed: %.0f s", total)]
            for status in [AudioStatus.good, .low, .clipping, .noise, .silent, .unreadable, .waiting] {
                let secs = secondsByStatus[status] ?? 0
                if secs > 0 {
                    lines.append(String(format: "%@: %.0f s (%.1f%%)", status.rawValue, secs, pct(status)))
                }
            }
            var warning: String?
            if pct(.noise) > 10 {
                warning = String(format: "About %.0f%% of the audio sounded like static or heavy noise. Check the microphone and its input volume before the next recording.", pct(.noise))
            } else if pct(.silent) > 10 {
                warning = String(format: "About %.0f%% of the recording had no audio signal. Check that the right microphone is selected.", pct(.silent))
            } else if pct(.clipping) > 5 {
                warning = String(format: "The audio clipped during about %.0f%% of the recording. Lower the input volume.", pct(.clipping))
            }
            if let warning { lines.append("Warning: \(warning)") }
            return (lines.joined(separator: "\n") + "\n", warning)
        }
    }

    /// Called on the audio queue for every mic buffer.
    func analyze(_ sampleBuffer: CMSampleBuffer, recording: Bool) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return }
        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        windowLength = max(1, Int(sampleRate * 0.05))
        if lock.withLock({ formatText == "unknown" }) {
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let text = String(format: "%.0f Hz, %d ch, %d-bit %@%@", sampleRate, asbd.mChannelsPerFrame, asbd.mBitsPerChannel,
                                isFloat ? "float" : "integer",
                                asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? ", non-interleaved" : "")
            lock.withLock { formatText = text }
        }

        let readable = readFirstChannel(sampleBuffer, asbd: asbd)

        let duration = Double(frames) / sampleRate
        let now = CACurrentMediaTime()
        if !readable {
            current = AudioQuality(status: .unreadable)
        } else if now - lastReport > 0.25 {
            current = evaluate()
        }
        if recording {
            lock.withLock {
                if counting { secondsByStatus[current.status, default: 0] += duration }
            }
        }
        if now - lastReport > 0.25 {
            lastReport = now
            onQuality?(current)
        }
    }

    /// Reads channel 0 of any linear PCM layout (8/16/24/32-bit integer,
    /// packed or padded, 32/64-bit float, interleaved or not) and feeds add().
    private func readFirstChannel(_ sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> Bool {
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return false }
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard let first = buffers.first, let data = first.mData else { return false }

        let flags = asbd.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let bigEndian = flags & kAudioFormatFlagIsBigEndian != 0
        let signed = flags & kAudioFormatFlagIsSignedInteger != 0
        let alignedHigh = flags & kAudioFormatFlagIsAlignedHigh != 0
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let frameBytes = Int(asbd.mBytesPerFrame)          // per buffer
        let container = nonInterleaved ? frameBytes : frameBytes / channels
        let bits = Int(asbd.mBitsPerChannel)
        guard frameBytes > 0, container > 0, container <= 8, bits > 0 else { return false }
        let n = Int(first.mDataByteSize) / frameBytes
        let bytes = data.assumingMemoryBound(to: UInt8.self)

        for i in 0..<n {
            let base = i * frameBytes
            var u: UInt64 = 0
            for b in 0..<container {
                let byte = UInt64(bytes[base + (bigEndian ? b : container - 1 - b)])
                u = (u << 8) | byte
            }
            let x: Float
            if isFloat {
                if container == 4 { x = Float(bitPattern: UInt32(truncatingIfNeeded: u)) }
                else if container == 8 { x = Float(Double(bitPattern: u)) }
                else { return false }
            } else {
                let containerBits = container * 8
                let usedBits = alignedHigh ? containerBits : min(bits, containerBits)
                var v = Int64(bitPattern: u & (usedBits == 64 ? UInt64.max : (UInt64(1) << UInt64(usedBits)) - 1))
                let half = Int64(1) << Int64(usedBits - 1)
                if signed {
                    if v >= half { v -= half << 1 }
                } else {
                    v -= half
                }
                x = Float(Double(v) / Double(half))
            }
            add(x)
        }
        return n > 0
    }

    private func add(_ x: Float) {
        let a = abs(x)
        windowSumSq += Double(x * x)
        windowCount += 1
        if a > windowPeak { windowPeak = a }
        totalSamples += 1
        if a >= 0.99 { clippedSamples += 1 }
        if windowCount >= windowLength {
            let rms = Float((windowSumSq / Double(windowCount)).squareRoot())
            windows.append((rms, windowPeak))
            if windows.count > 120 { windows.removeFirst(windows.count - 120) }
            windowSumSq = 0
            windowCount = 0
            windowPeak = 0
        }
    }

    private func evaluate() -> AudioQuality {
        defer { clippedSamples = 0; totalSamples = 0 }
        guard windows.count >= 20 else { return AudioQuality(status: .waiting) }
        func db(_ v: Float) -> Float { v > 0 ? 20 * log10(v) : -160 }
        let sorted = windows.map { $0.rms }.sorted()
        let floor = db(sorted[sorted.count / 10])
        let loud = db(sorted[sorted.count - 1])
        let peak = db(windows.map { $0.peak }.max() ?? 0)
        let clipFraction = totalSamples > 0 ? Double(clippedSamples) / Double(totalSamples) : 0

        let status: AudioStatus
        if loud < -65 {
            status = .silent
        } else if floor > -35 {
            status = .noise
        } else if clipFraction > 0.001 {
            status = .clipping
        } else if loud < -30 {
            status = .low
        } else {
            status = .good
        }
        return AudioQuality(status: status, speechLevel: loud, floor: floor, peak: peak)
    }
}
