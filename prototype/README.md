# SampleMate — note/key detection prototype + head-to-head

Prototype for tagging the detected musical **note** (one-shots) or **key** (loops) into
the exported filename, to wire into `CaptureEngine.exportSelection`.

## Files
- `detect.swift` — native detector (Accelerate/vDSP), app-portable.
  - NOTE: YIN fundamental estimator → nearest MIDI note. Gated on clarity.
  - KEY: tuning-corrected, triangular-spread, per-frame-normalized chroma → Krumhansl-Schmuckler
    correlation, optional bass-tonic prior. Gated on correlation + margin.
  - Env knobs: `SM_TUNE` (1=on tuning correction), `SM_BASS` (bass-prior weight, 0=off),
    `SM_NOGATE=1` (always commit a key).
- `kf.cpp` — reference arm running **libKeyFinder** (GPLv3) via libsndfile.
- `grade.py` — accuracy grader for the native detector vs ground-truth keys.
- `compare.py` — head-to-head: native vs libKeyFinder on identical ground-truth.

## Build
```sh
swiftc -O detect.swift -o detect -framework Accelerate -framework AVFoundation
P=$(brew --prefix); g++ -std=c++11 -O2 kf.cpp -o kf -I"$P/include" -L"$P/lib" -lkeyfinder -lsndfile
DYLD_LIBRARY_PATH=$P/lib python3 compare.py
```
Deps: `brew install libkeyfinder libsndfile` (pulls fftw, libomp).

## Ground truth
Key-labeled material from `~/Music/Samples`: "Only The Rhodes" (16 key-named progression
folders, 325 files — mostly **rootless Rhodes voicings / fills**, genuinely ambiguous),
Cookbook compositions (5 full-mix loops + 30 stems), BlueNote one-shots (10).
NOTE pipeline separately validated on 36 synthetic tones C2–B4.

## Results (measured)
NOTE (YIN), synthetic tones: **36/36** after fixing a window-boundary bug
(`loudestStart` must reserve `W + tauMax`; codex-found).

KEY, native vs libKeyFinder (both committing every file, `SM_NOGATE=1`):

| set | exact native | exact libKF | tonic native | tonic libKF |
|---|---|---|---|---|
| ALL (370) | 18% | 18% | 26% | 28% |
| Cookbook full-mix (5) | 60% | 80% | 60% | 80% |
| Rhodes (325) | 16% | 16% | 24% | 26% |
| Cookbook stems (30) | 30% | 37% | 43% | 47% |

## Conclusion
- NOTE detection (YIN) is reliable and shippable.
- KEY: native chroma+KS+tuning ≈ libKeyFinder on the full set (18% vs 18% exact). libKeyFinder's
  real edge is on **clean full mixes** (~80% vs 60%, small N) and slightly fewer fifth errors;
  it never abstains (more relative-key errors on ambiguous material). The native detector's
  ~18% earlier "deficit" was its confidence gate (policy), not detection quality.
- Both fail on the same genuinely-ambiguous material (rootless voicings, isolated stems) and
  make the same fifth error on Half_Forgotten (Eb→Bb).
- libKeyFinder costs GPLv3 (infects the whole app) + FFTW + C++ bridging. Remaining native lever
  not yet tried: porting Sha'ath tone profiles (the one ingredient that likely closes the
  clean-mix gap) — pure data, no GPL code.
