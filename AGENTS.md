# Sample Mate

Free, self-built macOS app that records system audio into a rolling RAM buffer, so the last N seconds or minutes of anything that played can be dragged out as a WAV (replaces the paid "Rolling Sampler"). Also has a Library Tagger (key detection, rename, undo). Swift, Core Audio process taps (macOS 15+), XcodeGen project.

Where: music / production / sample-mate, `~/Dev/music/production/sample-mate` (manifest row `sample-mate`, lead `sample-mate-lead`).

Read docs/ROADMAP.md first: goal, open tasks, path forward and decisions needed. `PLAN.md` has the full design, `README.md` what works today.

Build and verify:

```sh
xcodegen generate
xcodebuild -project SampleMate.xcodeproj -scheme SampleMate -configuration Debug build
xcodebuild -project SampleMate.xcodeproj -scheme SampleMate -destination 'platform=macOS' test
```

`SampleMate.xcodeproj`, `Info.plist`, the entitlements and `build/` are generated and gitignored: change `project.yml`, not the project. First capture asks for audio-capture permission. Exports land in `~/Music/SampleMate/`. The installed copy is `/Applications/SampleMate.app` (a copy, not a link to this folder).

`prototype/` holds the key-detection harness (`grade.py`, `compare.py`, read samples from `~/Music/Samples`); the Sha'ath vs Krumhansl-Schmuckler choice is provisional until tested on more than 5 samples.

## Lead
`sample-mate-lead` (manifest) owns the goal "Continuously capture system audio into a rolling buffer so any last-N-minutes moment can be saved." Its tasks are the open items in `docs/ROADMAP.md`; tasks tagged `#autonomous-safe` can run without the operator.
