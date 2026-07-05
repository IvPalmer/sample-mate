---
goal: Free, self-built macOS app that continuously captures system audio into a rolling buffer so any last-N-minutes of playback can be dragged out as a WAV, replacing the paid "Rolling Sampler" utility.
owner: operator
lead: sample-mate-lead
status: draft
next: Ship async/file-promise WAV export so long selections (multi-minute) no longer block the UI at drag start.
decisions_needed: []
blocked_by: []
---

## Open tasks

- [ ] Async / file-promise export for long drag-out selections (currently synchronous at drag start; hitches on multi-minute grabs) [T-001]
- [ ] Preview/audition on Alt+Click-hold via a separate output engine, excluding SampleMate's own process from the tap in All-audio mode to avoid feedback [T-002]
- [ ] Harden capture-epoch handling across sample-rate/device changes mid-session (partial today; each change should cleanly bump `captureEpochID` and show a waveform boundary) [T-003]
- [ ] Themes for the waveform view [T-004] #autonomous-safe
- [ ] Auto-trim-silence export option [T-005] #autonomous-safe
- [ ] BPM-in-filename export option [T-006] #autonomous-safe
- [ ] Additional zoom/scroll interactions: Z / middle-drag / Alt+Shift / Ctrl+Shift (wheel zoom already done) [T-007] #autonomous-safe
- [ ] Decide and record whether Sha'ath or Krumhansl-Schmuckler tone profile is the shipped default for the Library Tagger (harness comparison exists in `prototype/`; README notes only n=5 samples so far) [T-008]
- [ ] Validate tone-profile choice against a larger sample set before treating the n=5 comparison as final [T-009]

## Path forward

Core capture pipeline (process-tap → ring buffer → live waveform → drag-out WAV) and the Library Tagger (scan/detect/rename/undo) both work end-to-end today per the README and commit history.
The highest-leverage next step is making long-selection export asynchronous, since that is the one remaining correctness/UX gap in the primary capture-to-drag-out flow.
After that, audition and capture-epoch hardening close out the "riskiest parts" the plan calls out.
Themes, auto-trim-silence, and BPM-in-filename are polish items safe to batch later.
The Sha'ath-vs-KS tone-profile choice is functionally decided in code but should be treated as provisional until validated on more than 5 samples.
