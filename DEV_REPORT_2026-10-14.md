# Lecture Reflector Development Report — 2026-10-14

**Project:** Lecture Reflector — macOS lecture recording app
**Release:** 0.2.0 (build 2)
**Status:** Built and tested by Kevin with a reveal.js deck in Safari

## Summary

The first real recording with a reveal.js deck showed only the opening slide, and the lecturer picture-in-picture could not be moved or resized. Version 0.2.0 fixes slide capture, makes both the slides and the lecturer movable and resizable, and adds cropping of browser toolbars.

## Changes

### Slide capture (`Capture/SlideCapture.swift`)

- **Follows the deck into full screen.** Safari, reveal.js's "F" key and Keynote often present full screen in a *new* window, so the window chosen at the start stopped changing. A watchdog checks once a second: if an on-screen window of the presenting app fills a display, capture switches to it, and switches back to the original (same title, else largest) window when it closes. It also retries after a stream error.
- **Entire screen source.** The Slides picker lists each display. Display capture excludes Lecture Reflector's own windows.
- **Frames are copied out of ScreenCaptureKit's buffer pool** into app-owned buffers (GPU copy via Core Image). Holding SCK's IOSurfaces in the compositor and chapter detector can stall the stream.
- **Scaled to fit.** `scalesToFit` and `preservesAspectRatio` are set, so a window on a non-Retina display (or one that changed size) fills the frame instead of sitting small in the top-left corner. The capture resolution is updated when the window size changes by more than 2 pt.
- **Crop.** `SlideCrop` (top/bottom/left/right in points) trims browser toolbars or window edges. Points are used because a toolbar's height doesn't change when the window is resized. The last full frame is kept so crop changes show immediately on a static slide.
- The UI shows a *Capturing* line naming the window currently recorded.

### Layout and compositing (`Model/Layout.swift`, `Engine/Compositor.swift`, `Engine/Pipeline.swift`)

- `LecturerPlacement` stores a box as fractions of the frame (top-left origin) plus a width; height follows from the aspect ratio. Defaults reproduce the v0.1 positions.
- Lecturer placement is per layout (Rectangle PiP, Circle PiP, Floating Torso). Slide placement is shared by those layouts and Slides Only, default full frame. Sidebar keeps its fixed split.
- Corner radius of the rectangle PiP scales with its size.

### UI (`UI/ContentView.swift`, `Model/RecordingSession.swift`)

- `PlacementEditor` draws a dashed box over the live preview (orange for slides, blue for the lecturer). Drag inside to move, drag a corner to resize with the aspect ratio kept and the opposite corner fixed. These outlines are SwiftUI overlays and never reach the recording. Adjustments work while recording.
- *Full-Screen Slides* and *Reset Lecturer* buttons.
- *Crop slides* section with four sliders and *No Crop*.
- Persistence in UserDefaults: `lecturerPlacements`, `slidePlacement`, `slideCrops` (keyed by app bundle ID, or `display`).

### Build tooling

- `autobuild.sh` — watcher started once in Terminal. `.build-request` runs a Release build; `.install-request` runs `install.sh`. Output goes to `build-output/` (`status`, `build.log`, `issues.txt`, `install.log`). This lets Claude build and install without typing in Terminal or Xcode.
- `install.sh` — Release build, quit the running app, replace `/Applications/LectureReflector.app`, verify the installed version and executable.
- Version bumped to 0.2.0 (build 2) in `project.yml` and the generated project.

## Backups

The source tree before each round of changes is in `Backups/Sources-2026-10-14`, `-14b` and `-14c`. These are outside the build and can be deleted once 0.2.0 has been used for a while.

## Known limitations

- The full-screen detection matches a window whose size equals a display's size. An app that shows a display-sized window that is not the presentation would also be followed.
- Crop values are in points and assume the window is captured whole; they are not adjusted for Safari's compact vs. separate tab bar, so set the crop again after changing that preference.
- Not yet tested: Keynote and PowerPoint full screen, Chrome, two-display setups.

## Audio check (added evening of 2026-10-14)

A 39-minute recording came out as full-scale static after the Mac's input volume was set to maximum. The audio path (`CameraCapture` → `Recorder`) passes mic buffers to the AAC encoder unchanged and had not been modified since August, so the static was in the input signal.

- `AudioMonitor` (in `Capture/CameraCapture.swift`) reads each mic buffer without altering it and keeps the last 6 s as 50 ms windows. Status: *No signal* (loudest window below -65 dBFS), *Static or heavy noise* (10th-percentile window above -35 dBFS, i.e. no quiet gaps between words), *Clipping* (more than 0.1% of samples at full scale), *Low* (loudest window below -30 dBFS), else *Good*.
- The sidebar shows an *Audio check* line under *Mic level* with speech level, quiet floor and peak.
- While recording, time in each status is totaled. On stop, `audio-check.txt` (input format plus totals) is written next to the video, and an alert appears if static or no-signal covers more than 10% of the recording or clipping more than 5%.
- Thresholds were checked offline against the clean test clip (mostly *Low*, it was ~22 dB quiet), a loudness-normalized copy (*Good*) and the static recording (*Static* throughout).
- Source before this change: `Backups/Sources-2026-10-14d`.

## Mic format and automatic level correction (later the same evening)

- The audio check reported "can't analyze" with the Sennheiser Profile (24-bit integer). `AVCaptureAudioDataOutput.audioSettings` now requests 32-bit float mono at 48 kHz for every mic, so the recorder and the check always get one layout. The check's reader also handles any linear PCM layout. After this change the Profile recorded cleanly (-16 LUFS test clip, floor around -60 dB). It may also explain the earlier static recording.
- `audio-check.txt` now starts with the microphone name and its native format.
- `AudioLeveler` (in `Engine/Recorder.swift`) runs after the MP4 remux when *Correct audio level after recording* is on (default). It measures integrated loudness (BS.1770 K-weighting and gating), applies one gain toward -16 LUFS (+24 dB max boost, -12 dB max cut, skipped if within 0.5 dB), runs a -1 dBFS peak limiter, re-encodes only the audio (AAC 160 kbps) and copies the video. On failure the original file is kept and the reason goes into `audio-check.txt`. The result line is appended there too.
- Source before this change: `Backups/Sources-2026-10-14e`.

## Voice cleanup and a fuller audio check (2026-10-17)

A 20-minute recording with the DJI Mic Mini came out at -16 LUFS but with broadband rumble below 300 Hz (about -45 dBFS in pauses, no 50/60 Hz hum, so air or handling noise rather than electrical), a dull voice (3–8 kHz energy 18 dB below 300–3000 Hz: the lav was too far away or off-axis) and the limiter active on 19% of samples after a +3.9 dB boost, which flattens the voice.

- `AudioLeveler` (in `Engine/Recorder.swift`) gains a cleanup chain, run before the gain and limiter when *Clean up voice after recording* is on (default; greyed out unless level correction is on): a 24 dB/octave high-pass at 90 Hz, a +4 dB shelf above 3 kHz, and a 2:1 peak compressor (2 ms attack with 2 ms look-ahead, 150 ms release) whose threshold sits 8 dB above the recording's raw loudness, so it trims the same top of the voice on a quiet recording as on a loud one. The filters are RBJ cookbook designs on the existing `Biquad`.
- The leveler now makes three passes: raw measurement (loudness, noise floor, presence), loudness after the chain (compression changes it), then the rewrite. About 7 s for a 20-minute file.
- The limiter ceiling is now -1.5 dBFS (was -1) because AAC encoding overshoots a little; the "limiter active" figure now counts only samples reduced by more than 0.5 dB.
- `audio-check.txt` gains three lines: noise floor in pauses (10th percentile of 100 ms blocks), presence (3–8 kHz vs 300–3000 Hz) with a hint when it is below -12 dB ("voice sounds dull; move the mic closer or point it at your mouth"), and a warning when the limiter was active on more than 5% of samples ("level is being set by peaks").
- `LectureReflector --level <file.mp4> [--no-cleanup]` runs the leveler on an existing file and prints the report (developer use; the sandbox only lets it read files inside its container, so for testing the leveler was compiled with `swiftc` into a standalone tool together with `Recorder.swift`).
- Measured on the 2026-10-17 recording (already leveled once, so a worst case for peaks): below 70 Hz in pauses -49 → -59 dBFS; pause floor -45.5 → -48.7 dBFS (the rest of the rumble sits in the voice band and would need a spectral denoiser); presence gap -18 → -15 dB; loudness -16 LUFS; true peak -0.8 dBFS; loudness range 5.7 → 5.1 LU. The result was checked by measurement only, not by ear.
- Source before this change: `Backups/Sources-2026-10-17`.

## Monitor panel (2026-10-17, later)

For presenting from a reveal.js speaker view while Lecture Reflector records the main deck window: a small always-on-top panel to sit beside the speaker view.

- `UI/MonitorView.swift`, opened from *Open Monitor Panel* under the audio check (shown once a preview is running) or from the Window menu (*Monitor*). It shows the recording time, the current slide number (detected slide changes + 1) with time on that slide, the mic meter, and the audio-check status line. Timing refreshes once a second from `recordedSeconds` and `slideChanges`, two read-only accessors added to `RecordingSession` over the pipeline's recorder and chapter list.
- The window floats above other windows and joins full-screen spaces (`.floating`, `.canJoinAllSpaces`, `.fullScreenAuxiliary`), and its `sharingType` is `.none`, so an *Entire screen* recording does not include it. The main window can be hidden while recording.
- Added as a `Window` scene in `LectureReflectorApp`; project regenerated with XcodeGen. Built, not yet tried in a recording.

## Mouse pointer off by default (2026-10-18)

The pointer was being drawn into the captured slides. `SlideCapture.showsCursor` (static, default false) now feeds `SCStreamConfiguration.showsCursor`; *Show mouse pointer in slides* in Settings turns it back on, and `applyConfiguration()` re-sends the configuration to a running stream so the change takes effect without restarting the preview.

## Demo apps (2026-10-27, version 0.3.0 build 3)

For lectures that show the lecturer using other apps (Obsidian and Zotero for the Second Reader video), Lecture Reflector can now switch the slide capture to those apps mid-recording and back, in one take.

- **`Capture/SlideCapture.swift`.** New `demoBundleIDs` (set from the session) and `isDemoActive`. The window-source watchdog now ticks every 250 ms. Each tick, `checkDemo()` asks `NSWorkspace` for the frontmost app (on the main actor). If it is a chosen demo app, the capture switches to that app's front window, found with `CGWindowListCopyWindowInfo` because ScreenCaptureKit's window list has no z-order (layer 0, at least 400×300, not transparent), then matched to an `SCWindow` by window ID. If the slides app comes back to the front, `leaveDemo()` returns to the slides window used before the demo (else the same title, else the largest window). Lecture Reflector itself and non-demo apps are ignored. The full-screen-following check (`checkWindow()`) still runs once a second, but not during a demo. Demo windows are captured with the pointer always on and without the slide crop. A resized demo window gets its capture size updated. `onDemoChanged` reports the app name, or nil on return.
- **`Engine/Pipeline.swift`.** Slide-change detection is skipped while a demo is active, since typing and scrolling would otherwise mark dozens of chapters. New `markEvent(_:)` and `events` keep labeled moments, reset at each recording start.
- **`Model/RecordingSession.swift`.** `demoApps` (bundle ID → name), persisted in UserDefaults under `demoApps` and pushed to the capture. `demoAppChoices` lists apps with open windows plus those already chosen, minus the slides app. `demoAppName` is published for the UI. `chapters.txt` merges slide changes with "Demo: …" and "Back to slides" events in time order.
- **`UI/ContentView.swift`, `UI/MonitorView.swift`.** A *Demo apps* section with a toggle per app, a blue *Demo: App* badge beside REC, and a "Recording App" line in the Monitor panel during a demo.
- No new files, so the project didn't need regenerating. Version bumped to 0.3.0 (build 3) in `project.yml` and the project file.
- Source before this change: `Backups/Sources-2026-10-27`.

Not yet tested: Obsidian or Zotero windows other than the main one (e.g. a separate PDF reader window), two displays, and a demo app in full screen in its own Space.
