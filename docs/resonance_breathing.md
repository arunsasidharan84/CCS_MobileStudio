# Individual Resonance Breathing

Open **Resonance Breathing** in the Home study sequence (add or reorder it in Settings). This adult research module uses **Orbit PPG** (pulse intervals) or **xAMP-L10 ECG** (RR intervals). Connect from Home. For xAMP, label the electrode channel `ECG` and assign its ECG type in channel settings; a matching label alone is insufficient. A custom cardiac label can be entered at setup. One device/stream is locked for the entire session; missing labels never fall back to EEG channel zero.

## Protocol

With default parameters, the conventional quick sweep tests 6.5, 6.0, 5.5, 5.0 and 4.5 breaths/min. Each trial includes 30 seconds of settling excluded from analysis, then 120 seconds of measurement. Natural breathing rests default to 30 seconds for an abbreviated assessment (~14.5 minutes); select two-minute rests for ~20.5 minutes. Waiting for clean signal, feedback and retries add time. Comfortable, quality-approved epochs are ranked by fitted cardiac interval oscillation amplitude. A separate settling + 120-second confirmation follows a rest, then optional practice (five minutes by default). Inhale and exhale are equal by default; the cycle fraction is editable, with no holds.

The **experimental adaptive** version uses the same epochs and quality gates. It first tests 6.0, 4.5 and 6.5, then selects rates on a 0.1 breaths/min grid through expected information gain about the optimal rate. Stop after at least five accepted epochs if the model-based 95% interval spans ≤0.4 breaths/min, otherwise continue up to eight. Rejected or uncomfortable epochs never update the posterior. No recommendation is issued for an unfinished assessment. Boundary candidates are flagged for researcher review; this module does not automatically extend the adult range.

## Editable parameters and in-app methods

Expand **Assessment parameters** before starting. The app provides units, explanatory text, **Restore default parameters**, and validation for every field. Settings stay fixed during acquisition and are serialized in session JSON schema 2. The on-screen duration estimate, pacer, stopping logic, posterior grid, plot axes, quality gates and confirmation all use the selected values. References and a step-by-step algorithm explanation remain available in the **Methods and references** panel during setup and after acquisition.

| Parameter | Default | Allowed range / constraint |
| --- | --- | --- |
| Settling / measurement | 30 / 120 seconds | 10–120 / 90–300 seconds |
| Rest / practice | 30 / 300 seconds | 0–300 / 60–1800 seconds |
| Minimum / maximum pace | 4.5 / 6.5 breaths/min | Each 4–8; total span ≥0.5 |
| Conventional / adaptive step | 0.5 / 0.1 breaths/min | 0.25–1 / 0.05–0.5; adaptive grid ≤81 rates |
| Inhale fraction | 0.5 | 0.3–0.7; remainder exhale, no holds |
| Minimum / maximum adaptive trials | 5 / 8 | 3–12 / minimum–16 |
| Credible-width stopping target | 0.4 breaths/min | Grid step–full range |
| Clean intervals / paced cycles | 40 / 6 | 20–200 / 6–20; measurement must support cycles at minimum pace |
| Accepted / coverage fractions | 0.9 / 0.85 | Each 0.7–1 |
| Minimum amplitude / partial R² | 5 ms / 0.25 | 1–100 ms / 0.05–0.95 |
| Interval outlier fraction | 0.35 | 0.15–0.6 |
| Log-response noise floor / planning noise | 0.25 / 0.35 | 0.1–1 / floor–1 |
| Confirmation lower / upper amplitude ratios | 0.6 / 1.67 | 0.1–1 / 1–3 |

Rate grids include both endpoints even when the span is not divisible by the selected step. Conventional order is descending. Adaptive seeds are snapped to the chosen grid; subsequent rates minimize expected marginal entropy. Wider grids increase computation. Custom ranges and thresholds are adult research adjustments, not a validated pediatric or clinical protocol. HeartSync detector filter bands, 300 ms refractory period and 300–2000 ms absolute interval limits remain fixed and are disclosed in the UI.

## Analysis and limitations

The existing HeartSync causal detector is reused, with ECG 5–25 Hz and PPG 0.5–5 Hz filtering and 300 ms refractory time. It is a shared real-time detector, **not a newly clinically validated ECG/PPG algorithm**. Beat times use sample timestamps. Intervals outside 300–2000 ms or >35% from the recent median are rejected, without interpolation. Missing samples interrupt an epoch and require a fresh attempt. Even intervals passing these gates can contain detection errors, so retain and review raw cardiac recordings.

A least-squares fit of offset, linear drift and sine/cosine at the paced frequency operates directly on irregular interval midpoint times. The response is sinusoidal semi-amplitude in milliseconds. Partial R² compares against a separately fitted linear trend. SDNN and adjacent accepted-interval RMSSD are descriptive; neither selects the optimal rate. Quality gates require ≥40 clean intervals, ≥90% accepted intervals, ≥85% time coverage, ≥6 cycles, amplitude ≥5 ms and partial R² ≥0.25. Default measurement duration is 120 seconds; durations and quality thresholds are editable. Thresholds are engineering choices requiring physiological validation.

The adaptive model is `log(amplitude) = log(height) − 0.5 × ((rate − optimum)/width)²` with a uniform optimum grid, discrete height nuisance grid (10–320 ms) and width grid (0.4, 0.8, 1.5, 3.0 breaths/min). Gaussian log-response uncertainty has a conservative 0.25 floor. Expected marginal entropy uses 81-bin discretized predictive quadrature spanning the predicted log-amplitude range plus noise tails; default planning noise is 0.35. Updates use log-softmax stabilization. This is a Psi-inspired continuous physiological response model, separate from the HRD psychometric estimator. Its intervals are conditional on the unimodal stationary-response model, not validated frequentist coverage or diagnostic confidence. Drift, fatigue, changing depth, flat/multimodal responses and artifacts can invalidate that model.

Confirmation requires a valid, comfortable epoch with amplitude 0.6–1.67 times the nearest accepted discovery epoch's amplitude. This repeatability rule is a heuristic, not independent proof of baroreflex resonance; adaptive confirmation may use a rate not previously tested exactly. Do not interpret a successful confirmation as clinical validation.

No respiratory belt or blood pressure is acquired. Pacer adherence is self-reported; actual respiratory frequency, heart–respiration phase and baroreflex gain are **unmeasured**. PPG pulse timing and ECG R timing are distinct and should not be pooled. Results are provisional cardiac-response candidates. There is no LF/HF-based sympathetic/parasympathetic claim. Use gentle breathing and stop on discomfort; this adult range is not a pediatric protocol.

## Lifecycle and exports

Stop & save and back navigation export partial sessions before leaving. Backgrounding stops assessment/practice and attempts export. Export failures remain visible and can be retried. A snapshot can also be saved during assessment. Files use the global subject ID, output directory and `RESONANCE` tag:

- JSON: protocol, source, completion/confirmation status, all epochs and comfort/quality decisions, posterior and timestamped phase events.
- `_intervals.csv`: detected interval times, interval length, acceptance, phase and rate.
- `_cardiac.csv`: selected raw cardiac values, timestamps, source and sample rate.

Raw selected-channel samples are held in memory until export. These companion exports do not claim EDF acquisition or EDF-synchronized markers. Existing independent recordings are managed by their owning modules. Practice displays the last detected heart rate and continues pacing during signal loss with a visible warning.

## Scientific basis

[Shaffer & Meehan (2020), A Practical Guide to Resonance Frequency Assessment](https://www.frontiersin.org/journals/neuroscience/articles/10.3389/fnins.2020.570400/full) describes adult rate sweeps, artifact checks, comfort checks and the need to measure respiration. The quick rest, settling exclusion, numerical ranking and engineering quality gates here are explicit adaptations; they do not reproduce the full clinical multi-criterion assessment.

[Kontsevich & Tyler (1999)](https://pubmed.ncbi.nlm.nih.gov/10492833/) motivates choosing stimuli to maximize expected information. [Prins (2013), Psi-marginal](https://pubmed.ncbi.nlm.nih.gov/23750016/) motivates marginalizing nuisance parameters. Neither publication validates this breathing likelihood or protocol.

Run `flutter test test/resonance_test.dart` for deterministic signal, quality, posterior and source-routing checks. Hardware validation and human test–retest studies remain necessary before research claims of accuracy or time savings.
