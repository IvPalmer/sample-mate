# Sample Mate (DIY) — Build Plan

Product name: **Sample Mate** (`SampleMate.app`, bundle id `com.palmer.SampleMate`).
A free, self-built take on Bird's "Rolling Sampler" (birdsthings.com, $19).
Standalone macOS app that continuously records the computer's audio output into a
rolling RAM buffer, shows a live waveform, and lets you drag any selection out as a
WAV into Finder / Ableton / anywhere.

Status: v0.3 — WORKING end-to-end. Standalone macOS app (Swift/SwiftUI), Developer-ID
signed. Captures system audio via Core Audio process taps → lock-free ring + peak ring,
live waveform, drag-select → drag-out WAV. Listener modes (all / only-app / except-app).

Waveform model (changed from the original's oscilloscope after operator feedback): a
**scrollable left-to-right linear timeline**. Capture is **noise-gated** so silence
doesn't fill the buffer or advance the display — the frontier only moves while there's
real sound, and during silence the view freezes (and redraws stop → ~0 idle CPU).
History stays to the left; scroll to look back. New audio enters at the right; once the
viewport fills it right-anchors and scrolls. No wrap/overwrite. Exports get ~5ms edge
fades. Custom CoreGraphics NSView, 30fps, redraw-on-change only.

Perf (45s buffer, Volt @ 44.1k): **~0.4% CPU idle/silent**, ~8% while actively drawing
foreground, ~0 backgrounded; ~124 MB RAM (scales with buffer length). App icon: drawn
in code (CoreGraphics, via codex — no paid image API).

Known tradeoff: gating compacts silence out of the STORED audio, so a selection spanning
a former silence gap concatenates two sounds (mid-clip join, possible click). Acceptable
for a sampler per operator intent; revisit with display-only gating if timing fidelity
is needed. Still to do: preview/audition (Alt+click), themes, BPM-in-filename, async/
file-promise export for very long selections.

---

## What it does

- Always-on listener on the Mac's audio output. Hears **anything playing** —
  YouTube, Spotify, iTunes/Music, browser, **and** Ableton (Ableton's master goes
  out the same CoreAudio output, so the listener catches it too).
- Keeps only the **last N minutes** in RAM (configurable, up to ~10 min). Fixed
  memory footprint — never fills the drive.
- Live scrolling waveform.
- Highlight a region → **drag it out** as a real `.wav` into Finder, an Ableton
  track, anywhere.

## Primary use case

Capturing audio from **outside** Ableton (YouTube / Spotify / Music / any app),
plus Ableton itself. Retrospective "damn, I should've recorded that" capture.

---

## Architecture decision: ONE artifact, no plugin

Earlier idea was standalone **+** an Ableton plugin/extension. **Cut the plugin.**

- Ableton's output reaches the system output like everything else, so the
  standalone already hears it.
- A plugin can only hear the bus it's inserted on — it can NOT hear Spotify/browser,
  which is the main use case. The only thing a plugin can do that the tap cannot is
  capture a *single track/bus inside* Ableton (the OS only ever sees Ableton's final
  summed master). We don't need that for v1.

If per-track-inside-Ableton capture is ever wanted, add a JUCE plugin later that
reuses the same export/waveform core. Not now.

```
        ┌──────────────────────────────────────────┐
        │              Standalone app               │
        │              (Swift / AppKit)             │
        │                                           │
        │  Core Audio process tap ──► ring buffer   │
        │  (listener modes)          (last N min)   │
        │                               │           │
        │                     waveform ◄┘► export   │
        │                        UI         (WAV)   │
        │                                    │      │
        │                              drag out ────┼──►  Finder / Ableton / anywhere
        └──────────────────────────────────────────┘
```

---

## Capture: Core Audio process taps (macOS 14.4+)

No BlackHole, no virtual driver, no Multi-Output Device setup. Native API.

1. `CATapDescription` — choose what to listen to (see Listener Modes).
2. `AudioHardwareCreateProcessTap(desc)` → tap object.
3. Create a **private aggregate device** containing the tap.
4. `AudioDeviceCreateIOProcID` on the aggregate → IOProc reads the tap's stream
   into the ring buffer.

Reference implementation to crib from: **insidegui/AudioCap**
(https://github.com/insidegui/AudioCap) — demonstrates the full tap + aggregate +
IOProc flow and a per-process picker.

Process taps follow the **app**, not a device — so even if Ableton runs through a
separate audio interface instead of built-in output, the tap still catches it.
(A device-level tap would not — another reason to prefer process taps.)

### Listener modes (the "simple listener option")

Exposed as a small dropdown / mode switch in the UI, backed by the tap's
include/exclude process lists:

- **All system audio** — `CATapDescription` global mixdown. Hears everything,
  including notification dings / Slack pings (acceptable for "capture everything").
- **Only [app]** — `init(stereoMixdownOfProcesses:)` scoped to one app's process
  (e.g. only Ableton, only Spotify, only the browser). Clean, no notification bleed.
- **Everything except [apps]** — `init(stereoGlobalTapButExcludeProcesses:)` — e.g.
  exclude Slack/system so dings don't land in captures.

UI: a process picker populated from the running audio-producing apps.

---

## Components

### Ring buffer
- Lock-free SPSC, preallocated. No alloc/lock on the audio (IOProc) thread.
- Track an absolute, monotonically increasing **global frame counter**. Selections
  are frame ranges on that timeline, NOT ring indices.
- 48 kHz stereo f32 ≈ 23 MB/min → 10 min ≈ 230 MB.
- Export thread snapshots the region under a generation/overwrite check. If a
  selection has already wrapped out of the buffer, clamp visibly or fail loud.

### Waveform (live, always-on) — the defining feature

Target UX = the original (confirmed from Bird's manual): arm once, it sits listening,
the waveform **draws itself live and scrolls** with a moving write-head line. There is
**no save button** — you drag-select on the live waveform and **drag the selection out**.

Renderer decision (codex-reviewed): **custom layer-backed `NSView` + CoreGraphics**,
embedded in SwiftUI via `NSViewRepresentable`. NOT SwiftUI Canvas (too indirect for the
interaction density: precise mouse, selection overlay, drag-source, zoom/scroll, hover
audition), NOT Metal yet (premature — drawing pre-binned min/max columns on a thin strip
is cheap). Metal only if profiling demands it. This is what the original's
"Performance vs Accurate Display" modes hint at — they hit real CPU limits.

Peak data:
- **Multiresolution peak pyramid from the start** (L0 = 256-frame min/max, then 4× /
  16× / 64× / 256× reductions). Pick the level where 1 bin ≈ 0.5–2 px. A single
  resolution is fine for the 45s view but burns CPU at 10-min zoom-out.
- Built by a **non-realtime peak builder** that consumes newly-written ring frames a
  few ms behind the write head — NOT computed on the audio IO thread. Display may lag
  a few ms; capture must never.
- Per-channel min/max; render stereo lanes or combined by zoom.

### Selection / timeline model
- Selection = `[startFrame, endFrame]` on the global monotonic frame counter; carries
  its `epochID`.
- View window = `(offsetFrames, framesPerPixel)`; write-head = current write frame
  mapped to view coords.
- **Pause (Ctrl+Click) freezes the display/read head — it does NOT stop the tap.**
  Capture keeps filling the ring. If a frozen selection ages out of RAM, mark it
  expired; never let export silently emit the wrong audio.

### Drag-out
- **Eager real `.wav`**, NOT lazy file promises — Live wants a concrete file URL.
- But do **not** write the WAV synchronously inside SwiftUI `.onDrag` — a long
  selection is 17 MB (45s) to 230 MB (10 min). Export on a background queue on the
  drag-threshold (AppKit `beginDraggingSession`), show a brief "preparing" state, begin
  the session once the file exists.
- **Keep the file alive after drop** — Live references it from disk and writes a sibling
  `.asd`. Use an app-managed **export cache** with cleanup settings, not raw `/tmp`.
- Filename: `RS_20260621T153012_120bpm.wav`. Optional auto-trim-silence + add-BPM
  (both original options). BPM metadata is fine but Live's warp analysis overrides it.

### Preview / audition (Alt+Click-hold)
- Play the selected frame range out the default device through a **separate** output
  engine.
- **Feedback gotcha**: in *All audio* mode the tap will re-capture our own preview
  output. Exclude our own process from the tap (add our PID to the exclude list) or
  gate preview out of the buffer.

### Core ring contracts to add (for correct selection/export on a moving buffer)
- `availableFrameRange -> ClosedRange<Int>`
- `copyFrames(start:end:into:) -> Result` with explicit `.overwritten`
- `currentWriteFrame`
- `captureEpochID` — bumped on sample-rate / channel / device-tap restart; export
  refuses cross-epoch selections unless we intentionally resample/stitch.

---

## Riskiest parts (where the real work is)

1. **Tap lifecycle** — device switching, sleep/wake, permission revoked mid-session,
   aggregate device teardown. Most engineering effort lives here, not the happy path.
2. **Sample-rate / device changes mid-session** — most underestimated issue. Don't
   silently stitch 44.1 and 48 kHz into one buffer. Treat each change as a new
   **capture epoch**; show a small gap/boundary in the waveform.
3. **TCC permission UX** — the tap needs audio-capture permission
   (`NSAudioCaptureUsageDescription` usage string). Needs a first-run explainer
   screen *before* triggering the system prompt. NOTE: a bare CLI executable may not
   present the prompt cleanly — step 1 may need to be a minimal bundled `.app`
   rather than a pure command-line tool. Verify early.

---

## Build roadmap

Done (v0.1):
- [x] Capture: process tap → aggregate device → IOProc, permission, listener modes.
- [x] Lock-free ring buffer + WAV export (placeholder "save last N sec" button —
      to be REPLACED by the live-waveform + drag-out model below).

Live waveform + drag-out layer (codex-reviewed order):
- [x] Core contracts: `currentWriteFrame`, `availableFrameRange`, overwrite-aware
      `copyFrames`, `epochID` (bumped per capture session).
- [x] Peak ring (`PeakRing`) — 256-frame min/max envelope, SPSC, with slack so the
      reader never tears a wrapping bin. Fed by `CaptureSink` in one pass with the ring
      write. (Single resolution + on-draw aggregation; mip pyramid deferred — scanning
      ~100k bins/frame is negligible on Apple Silicon.)
- [x] `WaveformView: NSView` (layer-backed CoreGraphics) — live scroll, rainbow
      silhouette, write-head, pause/freeze, epoch invalidation. SwiftUI-embedded.
- [x] Selection in global frame coords; mapping frozen during the mouse interaction.
- [x] Wheel zoom (right-edge anchored). [ ] Z / middle-drag / Alt+Shift / Ctrl+Shift.
- [x] WAV export of selected frame range → export cache (`~/Music/SampleMate/`).
      NOTE: currently synchronous at drag start — fine for short grabs; make async or
      file-promise for long selections.
- [x] AppKit drag session with concrete file URL (Finder / Ableton). Drag image
      clamped to bounds.
- [ ] Preview/audition (Alt+Click-hold) — separate output engine; handle the
      self-capture feedback case (exclude our own PID in All-audio mode).

Riskiest part is NOT drawing — it's keeping selection/export correct while the buffer
moves (frozen selection wraps out of RAM, rate change mid-selection, export races the
writer, Ableton gets a file that later disappears). Solved by global frame ranges +
epoch IDs + overwrite checks + persistent export cache.

Then: harden capture lifecycle (device switch, sleep/wake), themes, auto-trim-silence,
BPM-in-filename. Optional later: JUCE plugin for inside-Ableton per-track capture.

---

## Debugging notes — hard-won (2026-06-21)

Two bugs blocked first capture on the dev machine (Volt 476P interface @ 44.1 kHz):

1. **"Permission needed", Start disabled.** Ad-hoc signing (`CODE_SIGN_IDENTITY: "-"`)
   gives a code-hash-based designated requirement that changes every rebuild, so macOS
   forgets the audio-capture (TCC) grant each build. **Fix:** sign with **Developer ID
   Application (Team C4SJBQAUZY)** → stable Team-ID + bundle-ID requirement → the grant
   persists across rebuilds. (Also: a CLI/ad-hoc target may never get an *effective*
   tap authorization even when preflight reports "granted".)

2. **IOProc fires but every sample is 0.0 (silent tap).** The aggregate device included
   the output device (Volt @ 44.1 kHz) as a sub-device while the tap ran at 48 kHz — a
   sample-rate mismatch yields an all-zeros tap. This is a known failure mode (correlates
   with output-device rate renegotiation). **Fix:** make the **tap the only input** —
   `kAudioAggregateDeviceSubDeviceListKey: []`, no main sub-device (per AudioTee's
   system-capture setup). AudioCap's sub-device approach is for *per-process* taps where
   device/tap rates usually already match. Verified: capture went from −∞ to −16.5 dBFS
   with the waveform drawing.

Instrumentation that found it: a live IOProc frame-counter + dBFS level meter in the UI
distinguished "IOProc not firing" vs "firing but silent" vs "render bug" in one reading.

## Verified environment (2026-06-21)

- macOS 26.3.1 (Apple Silicon) — process tap API fully available.
- Swift 6.3.1, Xcode 26.4.1.
- Dev audio device: **Volt 476P @ 44.1 kHz** (default output *and* system-output).
