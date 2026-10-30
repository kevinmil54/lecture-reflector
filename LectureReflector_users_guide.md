# LectureReflector User's Guide

**A product of Kevin Miller and Timely Snow LLC** — [timelysnow.com](https://timelysnow.com)

LectureReflector records you giving a lecture. It combines your slides and your webcam into one polished video, and writes a transcript for you. Everything happens on your Mac — nothing is uploaded anywhere.

## What you get

After every recording, LectureReflector saves a folder (named after your lecture title and the date) containing:

- **lecture.mp4** — the finished video: your slides with you composited on top, ready to upload to your LMS, YouTube, or anywhere else.
- **lecture.txt** — a plain-text transcript of everything you said.
- **lecture.srt** — the same transcript as subtitles. Most players and learning platforms accept this file directly as closed captions.
- **chapters.txt** — timestamps of when you changed slides, handy for adding chapter markers or navigating the video.

---

## First launch (one-time setup)

1. Open **LectureReflector**. macOS will ask for **Screen Recording** permission — click Allow, then quit and reopen LectureReflector (macOS requires a relaunch).
2. The first time you click **Start Preview**, macOS asks for **Camera** and **Microphone** — allow both.
3. The first time a recording finishes, LectureReflector downloads the speech-recognition model (about 150 MB). This needs internet once; after that, transcription works fully offline.

## Recording a lecture

### 1. Open your slides

Present however you normally do:

- **PowerPoint** — start your slide show, windowed or full screen.
- **Keynote** — use *Play Slideshow in Window* (or full screen).
- **reveal.js / Quarto** — open the deck in any browser.

Only the window you pick is recorded. Email notifications, other windows, your desktop — none of it can appear in the video, even if it covers your slides on screen. Just don't *minimize* the slide window (hiding it behind other windows is fine).

### 2. Set up LectureReflector

1. **Slides** — pick your presentation window from the list (click *Refresh Sources* if it's missing). If the deck goes full screen in a new window, Lecture Reflector follows it automatically; the *Capturing* line shows which window it is recording. For full-screen presenting you can instead pick **Entire screen**, which records whatever is on that display (Lecture Reflector's own window is left out).
2. **Camera** and **Microphone** — pick your devices. Speak normally and watch the level meter move; if it hits the red, move the mic back a little.
3. **Layout** — how you appear on the slides (you can change this live while recording):

   | Layout | What it looks like |
   |---|---|
   | **Rectangle PiP** | You in a small rounded rectangle (bottom-right to start; movable) |
   | **Circle PiP** | You in a circle with a white ring (bottom-right to start; movable) |
   | **Sidebar** | A wider video: slides at full size on the left, you in a tall panel on the right — nothing ever covers the slides. Choose this **before** recording; it records a wider frame. |
   | **Floating Torso** | Your background is removed and just *you* float over the slides |
   | **Slides Only / Camera Only** | Momentary toggles — e.g., switch to Camera Only for an introduction, then back |

4. **Crop slides** — if you present in a normal browser window, raise *Top* until the toolbar and tabs disappear from the preview. Raise *Bottom* a little to hide reveal.js's progress bar. The crop is remembered for each app.
5. **Lecture title** and **Save to** folder — used to name the output folder.

### Demonstrating other apps (Demo apps)

To show yourself using other apps in the middle of a lecture (say Obsidian and Zotero), tick them under **Demo apps** before you start. If an app isn't listed, open it and click *Refresh Sources*.

While you record:

- **Cmd-Tab to a demo app** and Lecture Reflector records that app's front window instead of your slides, with the mouse pointer showing. You stay in your picture-in-picture as usual.
- **Cmd-Tab between demo apps** (Obsidian ↔ Zotero) and the recording follows.
- **Cmd-Tab back to your slides app** (e.g. Safari) and the slides come back.
- Clicking Lecture Reflector or its Monitor panel, or switching to an app that isn't ticked (Finder, Mail), changes nothing.

A blue **Demo** badge next to REC (and a line in the Monitor panel) shows when a demo app is being recorded. `chapters.txt` marks each switch ("Demo: Obsidian", "Back to slides"). Slide-change detection pauses during a demo.

Demo apps need a **window** as the Slides source; they do nothing with *Entire screen*. The slide crop isn't applied to demo windows.

Tips: zoom the demo app's text up a step or two (Cmd-+) so it's readable in the video, and turn on Do Not Disturb so notifications don't pop up over the demo window.

### Arranging the slides and yourself

In every layout except Sidebar and Camera Only, the preview shows two dashed boxes: **orange** for the slides and **blue** for you. Drag inside a box to move it; drag a corner to resize it (its shape stays the same). The slides start at full frame; *Full-Screen Slides* puts them back. *Reset Lecturer* returns you to the default spot. You can adjust both while recording, and the outlines never appear in the video.

### 3. Record

1. Click **Start Preview**. The right side shows exactly what will be recorded.
2. Click **Record**. After the 3-2-1 countdown (you can turn it off in Settings), the red **REC** badge appears.
3. Lecture! Switch layouts anytime; the recording never skips a beat.
4. **Pause** if you need a break — paused time is cut out of the video seamlessly.
5. Click **Stop Recording**. The video is finalized in seconds, then transcription runs in the background (a few minutes for a typical lecture — you can already play the MP4 while you wait).
6. Click **Show Recording in Finder** to open the folder with all four files.

### 4. Edit by transcript (optional)

Transcription also saves `lecture-edit.txt`, with one line per stretch of speech:

```
[12 @ 00:01:23] So today, um, we'll talk about memory.
```

1. Click **Open Transcript for Editing** (or open `lecture-edit.txt` in any text editor).
2. Delete whole lines, or words within a line, that you want cut from the video. Leave the `[number @ time]` tag at the start of each line you keep. Changes to punctuation and capitals don't matter. Typing new words has no effect, since the video can only be cut.
3. Save the file and click **Cut Video from Edited Transcript…**, then choose the recording's folder.

Lecture Reflector writes `lecture-edited.mp4`, with `lecture-edited.srt` and `lecture-edited.txt` timed to match, and `lecture-edited-cuts.txt` listing exactly what was kept. `lecture.mp4` is never changed, so you can edit `lecture-edit.txt` again and re-cut as often as you like.

Recordings made before this feature have no word timing. Choosing one offers to transcribe it again with word timing first (this replaces its `lecture.txt` and `lecture.srt`).

Whisper's word timing is approximate. Lecture Reflector keeps a little room around each remaining word, but check the cuts in the edited video, especially after deleting single short words. Whisper also tends to leave out "um" and "uh", so those usually can't be found in the transcript to delete.

---

## Settings

- **Whisper model** — transcript quality vs. speed. `base` (default) is fast and good. `small` or `medium` are more accurate but slower; `large-v3` is the most accurate and much slower (one-time ~3 GB download). Changes apply to the *next* transcription.
- **Mirror camera** — flips your image horizontally, like a mirror. Turn on if your gestures look reversed to you.
- **3-second countdown** — on-screen 3-2-1 before recording starts.

## Tips

- **Do a 30-second test recording** before your first real lecture — check that your face is framed well and the audio level is healthy.
- **Sidebar for dense slides.** If your slides have small text or code, use Sidebar so nothing overlaps them.
- **Floating Torso works best** with even lighting and a plain background behind you.
- **Two displays are ideal** for full-screen presenting: slides on the projector, LectureReflector on your laptop screen. On one display, use windowed presentation mode so you can still see LectureReflector's controls — though recording continues fine even with LectureReflector hidden.
- **If the app ever crashes mid-lecture**, your recording is not lost: open the session folder and you'll find a `lecture.mov` playable up to a few seconds before the crash.

## Troubleshooting

| Problem | Fix |
|---|---|
| Slides window not in the list | Click *Refresh Sources*; make sure the window isn't minimized |
| "Could not list windows" | System Settings ▸ Privacy & Security ▸ Screen Recording → enable LectureReflector, then relaunch |
| Screen capture denied but you never saw a prompt | In Terminal: `tccutil reset ScreenCapture com.kevinmiller.lecture_reflector`, then reopen LectureReflector and allow the prompt |
| Black camera / silent mic | System Settings ▸ Privacy & Security ▸ Camera / Microphone → enable LectureReflector |
| Transcription failed but video saved | Usually the model download was interrupted — check your connection; the transcript can be regenerated later (the video is safe) |
| Video looks frozen on one slide | Check the *Capturing* line during preview. If it names the wrong window, pick the right one or choose *Entire screen*. If the slide window was closed, LectureReflector keeps the last slide visible rather than going black |
| Browser toolbar shows in the video | Under *Crop slides*, raise *Top* until the toolbar disappears from the preview. The crop is remembered for that browser |
| Want yourself somewhere else on the slide | In a Rectangle PiP, Circle PiP, or Floating Torso layout, drag your image in the preview to move it and drag a corner to resize it. Each layout remembers its own position. *Reset Lecturer* puts it back |
| Slides should be smaller or off to one side | Drag a corner of the orange box inward, then drag the box where you want it. *Full-Screen Slides* restores the full frame |
