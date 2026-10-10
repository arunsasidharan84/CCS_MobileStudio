# HRD port verification and interpretation — 9 October 2026

## What was verified

The source-of-truth executable is `orbit_HRD/ccs_hrd_ui.py`, with `LogisticPsiHandler` in `ccs_hrd.py` and the custom cardiac functions in `ccs_hrd_utilities.py`. The validator extracts the original Python functions/classes via AST and compares them directly with the compiled Rust FFI. It does not compare the Rust implementation with a rewritten approximation.

- 25 adaptive Psi trials: stimulus selection, posterior threshold, slope and mean ± SD/2 match Python to absolute tolerance 1e-10.
- Synthetic PPG at 62.5, 125 and 250 Hz: cleaned waveform tolerance 2e-6; identical peak indices; mean BPM tolerance 1e-10. MAD, source HRV score and sample entropy are checked separately.
- Synthetic ECG at 125 and 250 Hz: source **SciPy fallback** filtering/peaks/mean BPM match. This remains a regression check for the selectable legacy method; the default NeuroKit2 branch is now separately validated below.
- Original audio WAVs at 15, 60, 72.5, 120 and 199.5 BPM: synthesized PCM matches within one 16-bit count.
- The user's existing 10-trial PPG session shown in the screenshot was audited read-only: all adaptive deltas, half-BPM delivered rates, peak masks and posterior estimates match; maximum mean-HR difference is 1.42e-14 BPM. Its final offset (-26.705844477562074) and model steepness (5.195250352081511) reproduce the recorded result.
- Flutter tests exercise catch/timeout exclusion, valid-response updating, checkpoint/export completion, combined-slider direction/confidence storage, neutral rejection, explicit confirmation, and desktop/mobile results layouts.

The audit found and corrected a secondary diagnostic discrepancy: the Python runner calculates MAD/sample entropy from **all detected RR intervals**, while its custom PPG mean HR applies range/IQR rejection. Rust now keeps those separate, matching the runner. This correction does not change the adaptive HR baseline or existing Psi histories. Older trial JSON/PDF diagnostic values are not rewritten.

Run the real-session audit with:

```sh
cargo build --manifest-path rust/Cargo.toml
python3 tools/validate_hrd.py /path/to/orbit_HRD \
  rust/target/debug/libtrain_nidra_core.dylib /path/to/session.json
```

## What “valid” means here

**Software/numerical parity is supported for the tested pathways. Physiological and psychometric validity are separate.** Matching two implementations cannot demonstrate that every detected PPG peak is a true heartbeat. Independent annotated ECG/PPG recordings, hardware/audio latency checks, and repeat-session reliability are still needed. The default ECG method now ports the task-consumed NeuroKit2 0.2.12 outputs; the previous SciPy method remains an explicit legacy selection.

The HRD literature supports a signed rate-comparison paradigm and estimation of perceptual bias/precision, but does not validate this specific short protocol or implementation. [Legrand et al., 2022](https://pure.au.dk/ws/files/339865609/1-s2.0-S0301051121002325-main.pdf) describes HRD; [Kontsevich & Tyler, 1999](https://christophertyler.org/CWTyler/Pubtopics/PsiMethod/Psi.html) describes Bayesian adaptive estimation. The source's implementation specifically minimizes expected **alpha-marginal** entropy with beta marginalized and a fixed lapse, rather than implementing every feature of those published protocols.

Interpretation limits preserved from the source:

- `SubjResponse` models saying **faster**, not correctness. Catch trials and timeouts never update Psi.
- Negative offset means the fitted comparison function is shifted toward lower feedback rates; it is not a clinical deficit or an interoceptive ability score.
- With gamma=0 and lapse=0.05, the source's logistic function gives P(faster)=0.475 at alpha, not exactly 0.5. Its 50% crossing is alpha + ln(10/9)/beta. The interface calls alpha an “estimated rate offset” rather than claiming an exact equality point.
- Mean ± SD/2 is the source's display band. It is **not a 95% credible interval**.
- Ten total trials in the supplied session mean only eight posterior updates. This is a short exploratory estimate. A high reported beta or a narrow alpha band alone does not establish a reliable slope or strong perceptual precision; the marginal selection criterion targets alpha.
- The posterior uses the requested delta, matching Python, even if rate clamping/quantization changes the delivered delta. Both values are now exported so this discrepancy can be audited.
- The combined confidence slider is a **new response protocol**, not behaviorally validated as interchangeable with separate buttons and a subsequent rating. It keeps the same Psi likelihood/update and records mode, signed slider position, direction and confidence separately. Keep response mode consistent within a study, or counterbalance/analyze it explicitly.

## Interface changes

Results now separate an estimated-offset chart from measured-vs-feedback rates, with BPM/round axes, a zero reference, response colors and distinct catch/missed markers. Trial selection reveals measured rate, delivered feedback, requested delta, response and confidence. File paths and signal verification are collapsed into expandable sections, with a direct report action.

Session progress celebrates completed rounds rather than correctness. It does not expose measured HR, performance scores or adaptive offsets during responses. The combined slider uses left=slower, right=faster, confidence 1–9 by distance from centre. Centre is unselected; explicit confirmation submits both values together within the existing response deadline. Existing button keyboard mapping and optional 0–9 separate confidence remain available and are the default. New fields are appended after the original 18 CSV columns.

## Completed NeuroKit2 ECG port

The default native ECG path reproduces **NeuroKit2 0.2.12**'s fifth-order 0.5 Hz high-pass SOS filter, default 50 Hz powerline smoothing, gradient-based QRS identification/prominence peak selection, iterative Kubios/Lipponen–Tarvainen correction, and monotone-cubic interpolation of **period** followed by `60 / period`. Mean HR is the mean of the entire interpolated rate curve, not the mean of beatwise rates. Corrected peaks also feed MAD, HRV score and sample entropy as in the Python runner.

`tools/validate_hrd_neurokit.py` compares 24 cases using the exact `nk.bio_process` entry point: 125/250/500/1000 Hz, 45/72/120 BPM, clean/noisy signals with baseline drift and 50 Hz interference. Peak masks are identical; maximum cleaned-signal error is 1.49e-12 and rate-curve error is 5.68e-14 BPM. Another 210 contaminated peak sequences exercise **extra, missed, ectopic, and long/short** correction; corrected peak arrays match exactly. Flatline returns unavailable HR and no detected peaks. Checked-in golden fixtures make cleaning/detection/rate/artifact regression tests runnable without Python or NeuroKit2.

ECG now defaults to NeuroKit2 processing; an operator can explicitly select the earlier SciPy fallback. `ecgMethod` is persisted, actual processing identifiers are exported, and previous data is left intact. No runtime dependencies were added. NeuroKit2's MIT license and reference source hashes are preserved in `third_party/neurokit2`.

This is a port of **the ECG outputs HRD consumes**, not the entire NeuroKit2 package. Unused signal-quality, P/Q/S/T delineation and atrial/ventricular phase outputs are deliberately omitted. Invalid/nonfinite inputs are rejected; fewer than four corrected peaks yield unavailable rate and trigger task retry. We do not emulate Python exceptions in unused processing stages or silently replace the selected algorithm. Parity is pinned to the recorded release; behavior of arbitrary future NeuroKit2 versions is not claimed. Real annotated xAMP ECG and latency/reliability validation remain separate research checks.
