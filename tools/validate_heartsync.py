#!/usr/bin/env python3
"""Validate HeartSync exports in a folder tree.

Requires: numpy, pandas, scipy, pyedflib

Usage:
    python validate_heartsync.py /path/to/HeartSync

For each EDF, the script writes:
    <recording>_pulse_marker_alignment.png
    <recording>_marker_phases.csv

When given a folder, it also writes:
    heartsync_validation_runs.csv
    heartsync_validation_report.md

Important: existing HeartSync files contain a playback-request timestamp, not a
microphone-measured acoustic onset. Consequently this script can validate task
logic, cardiac timing and EDF marker delivery, but cannot prove that every tone
was audible or measure speaker latency.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import tempfile
from collections import Counter
from datetime import datetime
from pathlib import Path

os.environ.setdefault(
    "MPLCONFIGDIR", str(Path(tempfile.gettempdir()) / "heartsync-matplotlib")
)

import matplotlib
import numpy as np
import pandas as pd
import pyedflib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


STIMULUS_CODES = {
    ("frequent", "systole"): 1,
    ("rare", "systole"): 2,
    ("frequent", "diastole"): 11,
    ("rare", "diastole"): 12,
}
RESPONSE_CODES = {"frequent": 21, "rare": 22}
MARKER_CLASSES = {
    1: ("systole_frequent", "#2563eb"),
    2: ("systole_rare", "#dc2626"),
    11: ("diastole_frequent", "#06b6d4"),
    12: ("diastole_rare", "#f59e0b"),
}


def epoch_ns(values: pd.Series) -> np.ndarray:
    """Convert datetimes explicitly; pandas 3 may otherwise expose microseconds."""
    return pd.to_datetime(values).to_numpy(dtype="datetime64[ns]").astype("int64")


def one_pole_bandpass(values: np.ndarray, sample_rate: float) -> np.ndarray:
    """Match the zero-phase-style filter used by the HeartSync post-hoc pass."""
    dt = 1.0 / sample_rate
    high_alpha = (1 / (2 * math.pi * 0.5)) / (
        (1 / (2 * math.pi * 0.5)) + dt
    )
    low_alpha = dt / ((1 / (2 * math.pi * 8.0)) + dt)
    out = np.empty_like(values, dtype=float)
    previous_input = float(values[0])
    previous_high = 0.0
    low = 0.0
    for index, value in enumerate(values):
        high = high_alpha * (previous_high + float(value) - previous_input)
        low += low_alpha * (high - low)
        out[index] = low
        previous_input = float(value)
        previous_high = high
    return out


def find_peaks_like_app(cardiac: pd.DataFrame, refractory_ms: int = 600) -> np.ndarray:
    """Return peak timestamps using the same rules as the app's PPG post-hoc pass."""
    times = epoch_ns(cardiac["timestamp"])
    values = cardiac["value"].to_numpy(dtype=float)
    duration_s = (times[-1] - times[0]) / 1e9
    sample_rate = (len(times) - 1) / duration_s if duration_s > 0 else 250.0
    forward = one_pole_bandpass(values, sample_rate)
    filtered = one_pole_bandpass(forward[::-1], sample_rate)[::-1]
    median = float(np.median(filtered))
    p25, p75 = np.percentile(filtered, [25, 75], method="lower")
    robust_sd = max(float(p75 - p25) / 1.349, 1e-9)
    threshold = median + robust_sd * 0.5
    refractory_samples = max(1, round(max(600, refractory_ms) * sample_rate / 1000))
    prominence_window = max(2, round(sample_rate * 0.2))
    selected: list[int] = []
    for index in range(1, len(filtered) - 1):
        value = filtered[index]
        if (
            value < threshold
            or value < filtered[index - 1]
            or value <= filtered[index + 1]
        ):
            continue
        left = filtered[max(0, index - prominence_window) : index]
        right = filtered[index + 1 : min(len(filtered), index + prominence_window + 1)]
        if value - max(float(left.min()), float(right.min())) < robust_sd * 0.5:
            continue
        if selected and index - selected[-1] < refractory_samples:
            if value > filtered[selected[-1]]:
                selected[-1] = index
        else:
            selected.append(index)
    return times[np.asarray(selected, dtype=int)]


def find_peak_indices(values: np.ndarray, sample_rate: float) -> np.ndarray:
    """App-equivalent post-hoc PPG peak detection for a uniform EDF signal."""
    times = pd.date_range(
        "2020-01-01",
        periods=len(values),
        freq=pd.Timedelta(seconds=1 / sample_rate),
    )
    cardiac = pd.DataFrame({"timestamp": times, "value": values})
    peaks_ns = find_peaks_like_app(cardiac)
    origin_ns = epoch_ns(cardiac["timestamp"])[0]
    return np.rint((peaks_ns - origin_ns) * sample_rate / 1e9).astype(int)


def normalized_average_cycle(
    signal: np.ndarray, peaks: np.ndarray, sample_rate: float
) -> tuple[np.ndarray, np.ndarray, np.ndarray, int]:
    grid = np.linspace(0, 100, 201)
    cycles = []
    for left, right in zip(peaks[:-1], peaks[1:]):
        duration = (right - left) / sample_rate
        if duration < 0.35 or duration > 2.0:
            continue
        cycle = signal[left : right + 1]
        if len(cycle) < 5:
            continue
        baseline = float(np.median(cycle))
        scale = float(np.percentile(cycle, 95) - np.percentile(cycle, 5))
        if scale <= 1e-12:
            continue
        normalized = (cycle - baseline) / scale
        cycles.append(
            np.interp(grid, np.linspace(0, 100, len(normalized)), normalized)
        )
    if not cycles:
        raise ValueError("No valid cardiac cycles could be reconstructed")
    matrix = np.asarray(cycles)
    return grid, matrix.mean(axis=0), matrix.std(axis=0), len(matrix)


def boundary_for_plot(summary: dict[str, object]) -> tuple[float | None, str]:
    """Prefer the primary rare-correct functional boundary, then rare-all."""
    boundaries = summary.get("bayesianFunctionalBoundaries", {})
    if not isinstance(boundaries, dict):
        return None, ""
    for key, label in (
        ("rareCorrect", "Bayesian rare-correct"),
        ("rareAllResponded", "Bayesian rare-all"),
    ):
        result = boundaries.get(key)
        if isinstance(result, dict) and result.get("boundaryPercent") is not None:
            ratio = result.get("systolicToDiastolicRatio")
            probability = result.get("probabilityBest")
            suffix = (
                f"; ratio={ratio:.3f}, P(best)={probability:.3f}"
                if isinstance(ratio, (int, float))
                and isinstance(probability, (int, float))
                else ""
            )
            supported = bool(result.get("isEstablished", False))
            if "isEstablished" not in result:
                supported = (
                    isinstance(ratio, (int, float))
                    and isinstance(probability, (int, float))
                    and abs(math.log(max(float(ratio), 1e-9))) >= math.log(1.05)
                    and float(probability) >= 0.5
                )
            status = "supported" if supported else "exploratory—not established"
            return (
                float(result["boundaryPercent"]),
                f"{label} ({status}){suffix}",
            )
    return None, ""


def plot_edf_alignment(
    edf_path: Path,
    trial_file: Path | None,
    output_dir: Path,
) -> dict[str, object]:
    reader = pyedflib.EdfReader(str(edf_path))
    try:
        labels = reader.getSignalLabels()
        ppg_candidates = [
            index for index, label in enumerate(labels) if "PPG" in label.upper()
        ]
        if not ppg_candidates or "Marker" not in labels:
            raise ValueError(f"{edf_path.name} needs PPG and Marker channels")
        ppg_index = ppg_candidates[0]
        marker_index = labels.index("Marker")
        sample_rate = float(reader.getSampleFrequency(ppg_index))
        if reader.getSampleFrequency(marker_index) != sample_rate:
            raise ValueError("PPG and Marker channels must have the same sample rate")
        ppg = reader.readSignal(ppg_index)
        markers = np.rint(reader.readSignal(marker_index)).astype(int)
    finally:
        reader.close()

    peaks = find_peak_indices(ppg, sample_rate)
    filtered = one_pole_bandpass(one_pole_bandpass(ppg, sample_rate)[::-1], sample_rate)[
        ::-1
    ]
    grid, mean_cycle, std_cycle, cycle_count = normalized_average_cycle(
        filtered, peaks, sample_rate
    )
    stimulus_indices = np.flatnonzero(np.isin(markers, list(MARKER_CLASSES)))
    previous = np.searchsorted(peaks, stimulus_indices, side="right") - 1
    valid = (previous >= 0) & (previous + 1 < len(peaks))
    stimulus_indices = stimulus_indices[valid]
    previous = previous[valid]
    phases = (
        (stimulus_indices - peaks[previous])
        * 100.0
        / (peaks[previous + 1] - peaks[previous])
    )
    codes = markers[stimulus_indices]

    summary: dict[str, object] = {}
    if trial_file is not None:
        summary_file = trial_file.with_name(f"{trial_file.stem}_summary.json")
        if summary_file.exists():
            summary = json.loads(summary_file.read_text())
    fixed_boundary = float(summary.get("postHocSystolicEndPercent", 35.0))
    actual_systole = (phases <= fixed_boundary) | (
        phases >= 100 - fixed_boundary
    )
    intended_systole = np.isin(codes, [1, 2])
    accuracy = float(np.mean(actual_systole == intended_systole))
    bayes_boundary, bayes_label = boundary_for_plot(summary)

    figure, axis = plt.subplots(figsize=(13, 7), constrained_layout=True)
    axis.fill_between(
        grid,
        mean_cycle - std_cycle,
        mean_cycle + std_cycle,
        color="#94a3b8",
        alpha=0.22,
        label="Pulse-cycle SD",
    )
    axis.plot(grid, mean_cycle, color="#111827", linewidth=2.5, label="Average PPG")
    amplitude = max(float(np.ptp(mean_cycle)), 0.5)
    offsets = {1: 0.08, 2: 0.18, 11: -0.08, 12: -0.18}
    for code, (label, color) in MARKER_CLASSES.items():
        positions = phases[codes == code]
        y = np.interp(positions, grid, mean_cycle) + offsets[code] * amplitude
        axis.scatter(
            positions,
            y,
            s=42,
            color=color,
            edgecolor="white",
            linewidth=0.5,
            alpha=0.88,
            label=f"{label} (n={len(positions)})",
            zorder=4,
        )

    for boundary, linestyle, color, label in (
        (fixed_boundary, "--", "#475569", f"Fixed boundary {fixed_boundary:g}%"),
        (
            bayes_boundary,
            ":",
            "#7c3aed",
            f"{bayes_label}: {bayes_boundary:g}%" if bayes_boundary else "",
        ),
    ):
        if boundary is None:
            continue
        axis.axvline(boundary, linestyle=linestyle, color=color, linewidth=2, label=label)
        axis.axvline(100 - boundary, linestyle=linestyle, color=color, linewidth=2)

    axis.set(
        xlim=(0, 100),
        xlabel="Position within detected peak-to-peak cardiac cycle (%)",
        ylabel="Normalized PPG amplitude",
        title=(
            f"{edf_path.stem}\n"
            f"Stimulus target-phase agreement={accuracy:.1%}; "
            f"{cycle_count} pulse cycles averaged"
        ),
    )
    axis.grid(alpha=0.18)
    axis.legend(loc="upper center", bbox_to_anchor=(0.5, -0.13), ncol=3)

    output_dir.mkdir(parents=True, exist_ok=True)
    plot_path = output_dir / f"{edf_path.stem}_pulse_marker_alignment.png"
    figure.savefig(plot_path, dpi=180, bbox_inches="tight")
    plt.close(figure)

    marker_rows = pd.DataFrame(
        {
            "edf_sample": stimulus_indices,
            "seconds_from_edf_start": stimulus_indices / sample_rate,
            "marker_code": codes,
            "marker_class": [MARKER_CLASSES[code][0] for code in codes],
            "cardiac_phase_percent": phases,
            "fixed_posthoc_phase": np.where(
                actual_systole, "systole", "diastole"
            ),
            "planned_target_phase": np.where(
                intended_systole, "systole", "diastole"
            ),
            "target_phase_match": actual_systole == intended_systole,
        }
    )
    phase_path = output_dir / f"{edf_path.stem}_marker_phases.csv"
    marker_rows.to_csv(phase_path, index=False)
    return {
        "edf": str(edf_path),
        "plot": str(plot_path),
        "marker_phases": str(phase_path),
        "stimuli_assigned": len(phases),
        "target_phase_accuracy_from_edf": accuracy,
        "bayesian_boundary_percent": bayes_boundary,
        "bayesian_boundary_label": bayes_label,
    }


def assign_phases(
    trials: pd.DataFrame, peaks_ns: np.ndarray, boundary_percent: float
) -> tuple[np.ndarray, np.ndarray]:
    presented = epoch_ns(trials["presented_at"])
    percentages = np.full(len(trials), np.nan)
    phases = np.full(len(trials), "indeterminate", dtype=object)
    previous = np.searchsorted(peaks_ns, presented, side="right") - 1
    valid = (previous >= 0) & (previous + 1 < len(peaks_ns))
    rows = np.flatnonzero(valid)
    cycles = peaks_ns[previous[rows] + 1] - peaks_ns[previous[rows]]
    pct = (presented[rows] - peaks_ns[previous[rows]]) * 100.0 / cycles
    good = (cycles > 0) & (pct >= 0) & (pct < 100)
    rows = rows[good]
    pct = pct[good]
    percentages[rows] = pct
    systole = (pct <= boundary_percent) | (pct >= 100 - boundary_percent)
    phases[rows] = np.where(systole, "systole", "diastole")
    return phases, percentages


def find_matching_edf(trial_file: Path, edfs: list[Path]) -> Path | None:
    target_stamp = "_".join(trial_file.stem.rsplit("_", 2)[-2:])
    target = datetime.strptime(target_stamp, "%Y%m%d_%H%M%S")
    candidates = []
    for path in edfs:
        try:
            stamp_text = "_".join(path.stem.rsplit("_", 2)[-2:])
            stamp = datetime.strptime(stamp_text, "%Y%m%d_%H%M%S")
        except ValueError:
            continue
        candidates.append((abs((stamp - target).total_seconds()), path))
    return min(candidates, default=(float("inf"), None))[1] if candidates else None


def find_matching_trial(edf_file: Path, trials: list[Path]) -> Path | None:
    stamp_text = "_".join(edf_file.stem.rsplit("_", 2)[-2:])
    target = datetime.strptime(stamp_text, "%Y%m%d_%H%M%S")
    candidates = []
    for path in trials:
        try:
            trial_stamp = "_".join(path.stem.rsplit("_", 2)[-2:])
            stamp = datetime.strptime(trial_stamp, "%Y%m%d_%H%M%S")
        except ValueError:
            continue
        candidates.append((abs((stamp - target).total_seconds()), path))
    if not candidates:
        return None
    difference, path = min(candidates)
    return path if difference <= 5 else None


def read_edf_markers(path: Path | None) -> tuple[Counter, float | None]:
    if path is None:
        return Counter(), None
    reader = pyedflib.EdfReader(str(path))
    try:
        labels = reader.getSignalLabels()
        if "Marker" not in labels:
            return Counter(), None
        index = labels.index("Marker")
        values = np.rint(reader.readSignal(index)).astype(int)
        return Counter(values[values != 0]), float(reader.getSampleFrequency(index))
    finally:
        reader.close()


def ratio_metrics(trials: pd.DataFrame, stimulus: str, correct_only: bool) -> str:
    rows = trials[(trials["stimulus"] == stimulus) & trials["rt_ms"].notna()]
    if correct_only:
        rows = rows[rows["correct"].astype(str).str.lower() == "true"]
    systolic = rows.loc[rows["posthoc_phase"] == "systole", "rt_ms"]
    diastolic = rows.loc[rows["posthoc_phase"] == "diastole", "rt_ms"]
    if systolic.empty or diastolic.empty or diastolic.mean() == 0:
        return ""
    return f"{systolic.mean() / diastolic.mean():.4f}"


def validate_run(trial_file: Path, edfs: list[Path]) -> dict[str, object]:
    trials = pd.read_csv(trial_file)
    cardiac_file = trial_file.with_name(f"{trial_file.stem}_cardiac.csv")
    summary_file = trial_file.with_name(f"{trial_file.stem}_summary.json")
    summary = json.loads(summary_file.read_text()) if summary_file.exists() else {}
    cardiac = pd.read_csv(cardiac_file)
    boundary = float(summary.get("postHocSystolicEndPercent", 35.0))
    peaks = find_peaks_like_app(cardiac)
    phases, percentages = assign_phases(trials, peaks, boundary)
    exported_phase = trials["posthoc_phase"].fillna("indeterminate").to_numpy()
    exported_pct = pd.to_numeric(trials["posthoc_phase_percent"], errors="coerce").to_numpy()
    phase_reproduction = float(np.mean(phases == exported_phase))
    pct_error = np.abs(percentages - exported_pct)

    scheduled = pd.to_datetime(trials["scheduled_at"])
    presented = pd.to_datetime(trials["presented_at"])
    scheduling_delay_ms = (presented - scheduled).dt.total_seconds() * 1000
    gaps_ms = presented.sort_values().diff().dt.total_seconds() * 1000
    assigned = trials["posthoc_phase"].isin(["systole", "diastole"])
    target_match = assigned & (trials["target_phase"] == trials["posthoc_phase"])

    expected = Counter(
        STIMULUS_CODES[(row.stimulus, row.target_phase)]
        for row in trials.itertuples(index=False)
    )
    expected.update(
        RESPONSE_CODES[value]
        for value in trials["response"].dropna()
        if value in RESPONSE_CODES
    )
    edf = find_matching_edf(trial_file, edfs)
    actual, marker_fs = read_edf_markers(edf)
    marker_match = all(actual[code] == count for code, count in expected.items())
    bayesian = summary.get("bayesianFunctionalBoundaries", {})
    rare_correct = bayesian.get("rareCorrect") or {}
    rare_all = bayesian.get("rareAllResponded") or {}
    frequent_correct = bayesian.get("frequentCorrect") or {}

    minimum_interval = float(summary.get("minimumStimulusIntervalMs", 0))
    return {
        "run": trial_file.parent.name,
        "trials": len(trials),
        "rare_proportion": round(float((trials["stimulus"] == "rare").mean()), 4),
        "systole_target_proportion": round(
            float((trials["target_phase"] == "systole").mean()), 4
        ),
        "delivery_rate": summary.get("deliveryRate"),
        "configured_delivery_probability": summary.get(
            "configuredDeliveryProbability"
        ),
        "minimum_gap_ms": round(float(gaps_ms.min()), 3),
        "minimum_gap_valid": bool(gaps_ms.min() >= minimum_interval),
        "median_scheduler_lateness_ms": round(float(scheduling_delay_ms.median()), 3),
        "maximum_scheduler_lateness_ms": round(float(scheduling_delay_ms.max()), 3),
        "posthoc_assigned": int(assigned.sum()),
        "target_phase_accuracy": round(
            float(target_match.sum() / assigned.sum()), 4
        ),
        "posthoc_reproduction_accuracy": round(phase_reproduction, 4),
        "posthoc_percent_max_abs_error": round(
            float(np.nanmax(pct_error)), 4
        ),
        "edf_marker_sample_rate_hz": marker_fs,
        "edf_marker_count": sum(actual.values()),
        "expected_marker_count": sum(expected.values()),
        "edf_marker_counts_match": marker_match,
        "rare_correct_ratio": ratio_metrics(trials, "rare", True),
        "rare_all_responded_ratio": ratio_metrics(trials, "rare", False),
        "frequent_correct_ratio": ratio_metrics(trials, "frequent", True),
        "frequent_all_responded_ratio": ratio_metrics(trials, "frequent", False),
        "bayes_rare_correct_boundary_percent": rare_correct.get(
            "boundaryPercent"
        ),
        "bayes_rare_correct_ratio": rare_correct.get(
            "systolicToDiastolicRatio"
        ),
        "bayes_rare_correct_probability_best": rare_correct.get(
            "probabilityBest"
        ),
        "bayes_rare_all_boundary_percent": rare_all.get("boundaryPercent"),
        "bayes_rare_all_ratio": rare_all.get("systolicToDiastolicRatio"),
        "bayes_rare_all_probability_best": rare_all.get("probabilityBest"),
        "bayes_frequent_correct_boundary_percent": frequent_correct.get(
            "boundaryPercent"
        ),
        "bayes_frequent_correct_ratio": frequent_correct.get(
            "systolicToDiastolicRatio"
        ),
        "bayes_frequent_correct_probability_best": frequent_correct.get(
            "probabilityBest"
        ),
        "audible_playback_verified": False,
    }


def write_report(root: Path, runs: pd.DataFrame) -> Path:
    report = root / "heartsync_validation_report.md"
    newest = runs.iloc[-1]
    lines = [
        "# HeartSync validation report",
        "",
        f"Generated: {datetime.now().isoformat(timespec='seconds')}",
        "",
        "## Scope and limitation",
        "",
        "The checks validate trial balance, delivery rate, minimum inter-stimulus "
        "interval, post-hoc cardiac phase assignment, RT ratios, and EDF marker "
        "counts. Existing files do **not** contain a microphone/loopback acoustic-"
        "onset channel, so they cannot prove that every requested tone was audible "
        "or quantify speaker latency.",
        "",
        "## Per-run results",
        "",
        runs.to_markdown(index=False),
        "",
        "## Interpretation",
        "",
        f"- Latest run target-phase accuracy: "
        f"{100 * float(newest['target_phase_accuracy']):.1f}%.",
        f"- Latest run delivery rate: {100 * float(newest['delivery_rate']):.1f}%.",
        f"- Latest run minimum presentation gap: "
        f"{float(newest['minimum_gap_ms']):.1f} ms.",
        "- `presented_at` in these recordings is the Dart timer callback time and "
        "precedes confirmation from the asynchronous audio backend.",
        "- EDF markers are one-sample pulses in the `Marker` signal channel, not "
        "EDF+ annotations. They occur on the next recorded sample and are therefore "
        "quantized to the marker-channel sample period.",
        "",
        "## Marker codes",
        "",
        "| Code | Label | Meaning |",
        "|---:|---|---|",
        "| 1 | HEARTSYNC_frequent_systole | Frequent stimulus requested for systole |",
        "| 2 | HEARTSYNC_rare_systole | Rare stimulus requested for systole |",
        "| 11 | HEARTSYNC_frequent_diastole | Frequent stimulus requested for diastole |",
        "| 12 | HEARTSYNC_rare_diastole | Rare stimulus requested for diastole |",
        "| 21 | HEARTSYNC_RESPONSE_frequent | Frequent response button pressed |",
        "| 22 | HEARTSYNC_RESPONSE_rare | Rare response button pressed |",
        "",
        "The phase in a stimulus label is the **planned real-time target**. Use "
        "`posthoc_phase` and `posthoc_phase_percent` for outcome analysis.",
        "",
    ]
    report.write_text("\n".join(lines))
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "input",
        nargs="?",
        default=".",
        type=Path,
        help="One HeartSync EDF file, or a folder containing HeartSync exports",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Plot/report destination (default: input folder)",
    )
    args = parser.parse_args()
    selected = args.input.expanduser().resolve()
    root = selected.parent if selected.is_file() else selected
    search_root = root
    if selected.is_file() and root.name.startswith("Arun_HEARTSYNC_"):
        search_root = root.parent
    trial_files = sorted(
        path
        for path in search_root.rglob("*_HEARTSYNC_*.csv")
        if not path.name.endswith(("_cardiac.csv", "_marker_phases.csv"))
        and path.with_name(f"{path.stem}_cardiac.csv").exists()
    )
    edfs = [selected] if selected.suffix.lower() == ".edf" else sorted(root.rglob("*.edf"))
    if not edfs:
        raise SystemExit(f"No EDF files found at {selected}")
    output_dir = (
        args.output_dir.expanduser().resolve()
        if args.output_dir
        else (root if not selected.is_file() else selected.parent)
    )

    plot_results = []
    for edf in edfs:
        trial = find_matching_trial(edf, trial_files)
        result = plot_edf_alignment(edf, trial, output_dir)
        plot_results.append(result)
        print(
            f"{edf.name}: {result['stimuli_assigned']} stimuli, "
            f"target-phase agreement "
            f"{float(result['target_phase_accuracy_from_edf']):.1%}, "
            f"Bayesian boundary {result['bayesian_boundary_percent']}%"
        )
        print(f"  plot: {result['plot']}")
        print(f"  phases: {result['marker_phases']}")

    if trial_files and not selected.is_file():
        runs = pd.DataFrame(validate_run(path, edfs) for path in trial_files)
        csv_path = output_dir / "heartsync_validation_runs.csv"
        runs.to_csv(csv_path, index=False)
        report_path = write_report(output_dir, runs)
        print(f"\nWrote {csv_path}")
        print(f"Wrote {report_path}")


if __name__ == "__main__":
    main()
