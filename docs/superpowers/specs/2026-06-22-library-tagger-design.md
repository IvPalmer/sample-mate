# Sample Mate — Library Tagger module (design)

Status: approved design, 2026-06-22. Pre-implementation spec.

## Overview

A dedicated **batch tagging** module inside Sample Mate that reads a folder (or
individual files), detects each sample's musical **note** (one-shots) or **key**
(loops), and writes the result into the **filename** (Sononym-style rename), behind a
**preview → approve → apply** flow with an undo log.

This is separate from — but shares a detection core with — the live-capture export path
(`CaptureEngine.exportSelection`), which will tag what's captured/selected in a later phase.

## Goals

- Point it at a directory (recursive) or files; get notes/keys written into filenames.
- Never mutate files without an explicit, reviewable Apply step.
- Reversible: one-click undo of the last applied batch.
- Idempotent: re-scanning an already-tagged folder skips already-tagged files.
- Keep Sample Mate dependency-free and license-clean (native detector, no GPL).

## Non-goals (v1)

- Embedded WAV metadata tags (chose filename-only). Deferred.
- Camelot/Open-Key notation, BPM-in-filename (separate roadmap item), folder auto-watch.
- Wiring the shared detector into `exportSelection` — phase 2, reuses the same core.

## Architecture

### Shared core — `PitchKeyDetector`

New file `SampleMate/Audio/PitchKeyDetector.swift`, lifted from `prototype/detect.swift`.
Pure, no app state, no I/O:

```
struct Detection {
    enum Kind { case note(name: String, octave: Int, midi: Int)
                case key(tonic: Int, minor: Bool)
                case none }                       // .none = below confidence gate
    let kind: Kind
    let confidence: Double
}
func analyze(_ mono: [Float], sampleRate: Double) -> Detection
```

- NOTE: YIN fundamental estimator on the loudest in-bounds window → nearest MIDI note.
- KEY: tuning-corrected, triangular-spread, per-frame-normalized chroma → tone-profile
  correlation. **Tone profiles: Sha'ath** (ported numeric constants — data, not GPL code),
  with Krumhansl-Schmuckler retained as a fallback constant.
- Routing (note vs key) decided inside `analyze` from signal behavior (see below), not by
  the caller, so both consumers (tagger, future export path) get consistent decisions.

Consumed by the Library Tagger now; by `CaptureEngine.exportSelection` in phase 2.

### UI integration — a second tab

`RootView` becomes a host with a top-level mode switch: **`Capture` | `Tag Library`**
(tab in the same window; same dark/pink theme and `accent`). The existing capture UI moves
into the Capture tab unchanged. The Tag Library tab hosts the new module's views.

### Module components (Tag Library tab)

1. **`FolderScanner`** — drag-and-drop a folder/files or `NSOpenPanel`. Recursively
   enumerates `.wav .aif .aiff .flac` (`.mp3` optional, off by default). `NSOpenPanel`
   yields **security-scoped** access to the chosen folder, which covers in-place rename in
   the sandboxed app — no broad file-access entitlement needed. Persist a security-scoped
   bookmark for the session so Apply/Undo can act on the same scope.

2. **`TaggerEngine`** (`@Observable`) — for each file: load to mono via `AVAudioFile`, run
   `PitchKeyDetector.analyze`, build a `TagProposal`. Runs on a bounded-concurrency
   `TaskGroup` off the main thread; publishes progress (`done/total`) and per-row results as
   they complete.

   ```
   struct TagProposal {
       let url: URL
       let detection: Detection
       var proposedName: String        // empty when detection == .none
       var apply: Bool                 // user-toggled; auto-set from confidence gate
       enum Status { case proposed, alreadyTagged, untaggable, error(String) }
       var status: Status
   }
   ```

3. **`NameFormatter`** — pure. `format(original: String, detection: Detection, options) -> String?`.
   - Options: position (suffix before extension), separator (`" - "` | `"_"`),
     accidental spelling (sharp | flat), include octave for notes (bool), key format (`Am`).
   - **Idempotency:** a regex recognizes an existing trailing note/key token; re-tagging
     replaces it rather than appending a second. `.none` detection → returns nil (no rename).
   - **Collision:** if the target name already exists on disk, append ` (2)`, ` (3)`, …
   - Returns nil when the new name equals the old (already correct) → row marked
     `alreadyTagged`.

4. **Preview table** — SwiftUI `Table` of proposals: columns
   `[✓ apply · filename · detected (note/key) · confidence · → new name]`.
   Filter by status/confidence; a confidence-gate slider auto-checks only rows above the
   threshold. Nothing on disk changes until **Apply**.

5. **`TagApplier` + undo** — for checked rows, `FileManager.moveItem` (rename) within the
   scoped folder. **Companion files:** an Ableton analysis sibling `<name>.wav.asd` (and
   `.reapeaks`) is renamed in lockstep so it isn't orphaned — `Piano 13.wav` → `Piano 13 - C#3.wav`
   also moves `Piano 13.wav.asd` → `Piano 13 - C#3.wav.asd`. The undo log records the companion
   moves too. Writes an **undo log** (JSON array of `{old, new, appliedAt}`) to
   `Application Support/SampleMate/undo/<timestamp>.json`. "Undo last batch" reverses the
   most recent log (rename new→old, skipping any the user changed since). Apply is atomic
   per-file; a mid-batch failure leaves a valid partial undo log.

## Data flow

```
pick folder/files
   └─ FolderScanner → [URL]
        └─ TaggerEngine.analyze (concurrent) → [TagProposal]
             └─ Preview table (review / toggle / filter)
                  └─ Apply → TagApplier (rename + undo log)   ── Undo last batch ──┐
                                                                                    └─► reverse
```

## Detection routing (note vs key)

Inside `analyze`, after a cheap tonal analysis:

- **NOTE** when the sound is short (≈ < 2 s of tonal content) **and** has a stable
  monophonic pitch (high YIN clarity sustained across the window).
- **KEY** when it's longer / polyphonic (several strong chroma classes).
- **`.none`** (no tag) when percussive / atonal / low-confidence — e.g. drum folders.
  Better to leave a file alone than write a wrong tag.

Confidence gate thresholds are constants in the detector; the preview slider gates which
rows are *auto-checked* for Apply (UI-level), independent of the detector's own `.none` cut.

## Sha'ath profiles + validation

Port the Sha'ath major/minor tone-profile constants into `PitchKeyDetector`. Validate the
change with the existing harness (`prototype/compare.py`, `grade.py`): confirm it improves
the clean full-mix accuracy without regressing the overall set, vs the current
Krumhansl-Schmuckler constants and vs libKeyFinder. Keep KS available as a fallback constant
behind a build/debug flag for comparison.

## Error handling

- Unreadable/corrupt/unsupported file → `TagProposal.status = .error`, skipped, batch
  continues.
- Drums/atonal/low-confidence → `.untaggable`, left untouched.
- Apply rename failure (permissions, disk) → surfaced on the row; partial undo log stays valid.
- Re-scan of tagged folder → `.alreadyTagged`, unchecked by default.

## Sandbox / permissions

Sample Mate is sandboxed (audio-capture entitlement). File access for the tagger comes from
the user's `NSOpenPanel`/drag selection (security-scoped). Persist the scoped bookmark for the
session; call `startAccessingSecurityScopedResource` around scan/apply/undo. No new broad
entitlement required for v1.

## Testing

- `NameFormatter` — unit tests (XCTest): suffix/prefix, separators, sharp/flat, octave on/off,
  idempotent re-tag (no double token), collision counter, already-correct → nil.
- `PitchKeyDetector` — golden-case XCTests on a few known samples (notes from synthetic tones,
  keys from the labeled Cookbook full mixes); broad accuracy stays validated by the prototype
  harness.
- `TagApplier` — temp-dir integration test: apply a batch, assert renames + undo log, run undo,
  assert originals restored.

## Phasing

- **v1 (this spec):** Tag Library tab — scan, detect (note+key, native+Sha'ath), preview,
  apply rename, undo. wav/aiff/flac.
- **Phase 2:** reuse `PitchKeyDetector` in `CaptureEngine.exportSelection` to tag captured
  selections; add BPM token (roadmap item); optional embedded metadata.
