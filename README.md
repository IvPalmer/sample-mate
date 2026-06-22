# Sample Mate

A free, self-built macOS app that continuously records your computer's audio output
into a rolling RAM buffer, so you can grab the last N seconds of **anything** you were
playing — YouTube, Spotify, Music, a browser, Ableton, anywhere — after the fact.

Inspired by Bird's "Rolling Sampler" ($19, birdsthings.com). See [PLAN.md](PLAN.md)
for the full design and roadmap.

## Status

Working today (v0.2):

- System-audio capture via the native **Core Audio process-tap API** (macOS 15+) —
  no BlackHole / virtual driver needed.
- **Listener modes**: All audio · Only [app] · Everything except [app].
- Lock-free rolling RAM buffer (15s–10min) + a downsampled peak ring.
- **Live waveform** that draws itself and scrolls as audio plays, rainbow-gradient
  silhouette with a moving write-head (custom layer-backed `NSView`).
- **Drag-select + drag-out**: drag across the waveform to select, then drag the
  selection straight out to Finder or an Ableton track — writes a 32-bit float WAV in
  `~/Music/SampleMate/` on drop. `Ctrl+Click` pauses; Scroll mode scrolls back.

Known v0.2 limitations / next:
- Drag-out exports the WAV synchronously at drag start (fine for short grabs; a
  many-minute selection will hitch). Async/file-promise export is a follow-up.
- No preview/audition (`Alt+Click-hold`) yet; no themes, auto-trim-silence, or
  BPM-in-filename yet; capture-epoch handling on sample-rate/device changes is partial.
  (Roadmap in PLAN.md.)

## Build & run

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project SampleMate.xcodeproj -scheme SampleMate -configuration Debug build
# or just open SampleMate.xcodeproj in Xcode and Run.
```

On first capture, macOS asks for **audio-capture** permission — allow it.

## Distribution (later)

Currently ad-hoc signed for local dev. For distribution: set a Developer ID identity,
enable Hardened Runtime, notarize. Note the permission check uses a private TCC SPI,
which is fine for Developer ID / notarized distribution but **not** the Mac App Store
(would need to be gated out for that path).

## Credits

Core Audio process-tap plumbing (`CoreAudioUtils`, `AudioRecordingPermission`,
`AudioProcessController`) adapted from Guilherme Rambo's
[AudioCap](https://github.com/insidegui/AudioCap).
