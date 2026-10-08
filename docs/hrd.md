# Heart Rate Detection (HRD)

The new **Heart Rate Detection** module ports the runnable `orbit_HRD/ccs_hrd_ui.py` task into MobileStudio. It is separate from HeartSync's cardiac-phase oddball. Select it on the dashboard, or add/reorder it in Settings → Study Sequence. Existing settings gain the new module once; subsequent custom ordering is preserved.

## Run

1. Enter the participant code on the dashboard and connect the hardware.
2. For Orbit choose PPG, channel `PPG`. For xAMP-L10 configure the desired channel's **type as ECG** in channel settings, then enter its exact label in HRD. An ECG channel may be inside the amplifier's EEG stream.
3. Set trial count, catches and acquisition duration (defaults: 10 / 2 / 16 seconds). The optional source field uses `deviceProfileId/streamId` and disambiguates simultaneous devices. With it empty, the first matching valid cardiac stream is locked for the run.
4. Press Start, read the instructions, then Begin. Each trial has 1 second of fixation, fresh acquisition, then feedback. Choose faster with **1 / left arrow** or slower with **0 / right arrow**, or tap the corresponding button. Escape/Close stops and saves partial results.
5. Signal gaps restart the current collection window. Missing/invalid HR prompts retry rather than fabricating a baseline. Simulation is explicit, labeled DEMO, and never writes hardware EDF.

Auditory feedback reproduces the source pulse waveform and ten-beat playback (two repetitions of its five-beat WAV). Visual mode reproduces the warning bell followed by a rate bar. Response duration is `max(5 * 60 / presentedBPM, 8)` seconds. Confidence 0–9 is an optional 15-second extension, disabled by default because the source UI runner does not collect it.

## Native computation and footprint

`rust/src/hrd.rs` implements the signed logistic marginal-Psi algorithm, fourth-order bandpass resulting from the source's order-2 Butterworth bandpass, zero-phase filtering, median/Savitzky–Golay PPG processing, peak selection, RR/IQR rejection, mean HR, robust MAD, source HRV score/sample entropy, instantaneous rate curves, simulated signals and PCM generation. It introduces **no Rust or Flutter dependencies**.

Dart owns acquisition subscriptions, protocol state, response timing, plots and document layout. Native work runs in a background isolate using the existing shared library. Report rendering also runs in a background isolate. Native handles are local to that isolate and always released. The posterior is only 10,200 doubles (~80 KiB); the source's 138 MB rate sound library is replaced with procedural synthesis plus its ~183 KiB bell asset. Trial signal buffers cover one epoch, not the whole session; snapshots are written to disk per trial.

## Parity and deliberate corrections

| Behavior | Implementation / validation |
| --- | --- |
| Stimulus grid | 102 levels, -50.5 through +50.5 BPM in 1 BPM increments |
| Alpha / beta grids | alpha -50.5…50.5 (102); beta 0.1…10.0 (100) |
| Logistic model | gamma 0, lapse 0.05; exponent clipped to ±20 |
| Stimulus selection | Expected entropy of the alpha marginal; first minimum wins |
| Responses | Probability of saying faster, not probability of being correct |
| Catch allocation | First trial is catch; remaining catches in last half, fallback to all remaining trials when necessary |
| Catch offset | Uniform selection from -40…40 in steps of 10 BPM |
| Posterior updates | Valid non-catch responses only |
| Feedback quantization | Actual HR + selected delta; clamp 15…199.5, round to half BPM with Python ties-to-even |
| Estimate bounds | Mean ± SD/2, preserving source definition; **not** a credible interval |
| PPG | Source custom pipeline; compared cleaned samples, peak indices and BPM at 62.5, 125 and 250 Hz |
| ECG | Source SciPy fallback; compared cleaned samples, R peaks and mean BPM at 125 and 250 Hz |
| Audio | Representative source WAV comparisons within one 16-bit PCM count |

**Not yet full parity with optional NeuroKit2:** the source can use NeuroKit2's ECG cleaning, artifact correction and interpolated `ECG_Rate` mean when that package is installed. This port implements the source's documented dependency-free fallback instead. It must not be described as numerically identical to that optional branch. Live xAMP-L10 / Orbit validation and audio hardware latency measurement remain necessary. The simulation is a deterministic native 72 BPM demonstration, not a reproduction of the source's random EEG simulator.

Source bugs are corrected: missed responses remain empty rather than becoming “slower”; an unupdated posterior remains unavailable on early catches; Orbit uses the cardiac stream's own sample rate; stream labels/types are respected; stop cancels pending trial work; physiological recording closes before export/report generation. Psi is updated with the **requested delta**, matching the source even when rate quantization/clamping changes the delivered difference.

## Outputs

Files follow shared subject/HRD/session naming and the configured export root:

- CSV with all 18 source behavioral columns. Invalid/missing values are empty. Numeric results retain full precision (the source rounded selected fields to one decimal).
- Session JSON: config, actual source, randomized catch plan, response history, posterior estimates and completed rows. NaNs serialize as null.
- Per-trial JSON: actual sample timestamps, native sampling rate, raw/cleaned signal, peak mask, rate curve and HRV diagnostics.
- SVG: both source summary panels (Psi bias/deltas and actual/presented rates).
- PDF: summary and one signal/rate/response page per completed trial.
- Shared physiological EDF and marker CSV when recording is enabled. Markers: feedback 710, slower 711, faster 712, timeout 713.

CSV/JSON are checkpointed after each completed trial. Stop exports partial trials; unfinished trials do not enter the posterior. Visualization uses Flutter `CustomPainter` and Dart PDF/SVG layout, with no plotting package or Python runtime shipped in the app.

## Verification and builds

```sh
cargo test --manifest-path rust/Cargo.toml --lib
cargo build --manifest-path rust/Cargo.toml
python3 tools/validate_hrd.py /path/to/orbit_HRD
flutter test --no-pub
bash rust/build_android.sh
flutter build apk --debug --no-pub
```

The development parity script requires NumPy/SciPy and extracts the source algorithms using AST, without importing Pygame/Tk/BLE dependencies. Native FFI tests run when the macOS debug library is available. Android libraries must be regenerated after Rust changes (the tracked libraries have been updated). macOS/Windows use the existing native build/packaging workflow. The local macOS application build currently fails due to Xcode CoreDevice framework mismatch and existing deployment targets below the installed Xcode's minimum; the Rust desktop library and Flutter tests compile independently.
