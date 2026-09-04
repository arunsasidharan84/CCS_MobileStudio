#!/usr/bin/env python3
"""Replay an EDF like a live stream and benchmark TrainNidra sleep scoring.

Dependencies:
    python -m pip install numpy scipy scikit-learn pyedflib onnxruntime

The optimizer compares bundled TinySleepNet variants and clinically useful
single-channel/mastoid derivations. It selects on the first 70% of the night
and reports an untouched chronological 30% validation result. The replay
command then emits one causal score per 30-second epoch in stream order.
"""

from __future__ import annotations

import argparse
import json
import math
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

import numpy as np
import onnxruntime as ort
import pyedflib
from sklearn.metrics import accuracy_score, cohen_kappa_score, confusion_matrix, f1_score

STAGES = ("Wake", "N1", "N2", "N3", "REM")
STAGE_INDEX = {stage: index for index, stage in enumerate(STAGES)}


@dataclass(frozen=True)
class Derivation:
    signal: str
    reference: str | None = None

    @property
    def label(self) -> str:
        return self.signal if self.reference is None else f"{self.signal}-{self.reference}"


def load_reference(path: Path) -> list[int | None]:
    payload = json.loads(path.read_text())
    rows = payload[0] if payload and isinstance(payload[0], list) else payload
    return [
        STAGE_INDEX[row["stage"]]
        if row.get("stage") in STAGE_INDEX and row.get("clean", 1)
        else None
        for row in rows
    ]


class EdfEpochStream:
    """Reads calibrated EDF samples in bounded chunks and yields 30 s epochs."""

    def __init__(
        self,
        path: Path,
        derivation: Derivation,
        chunk_seconds: float = 1.0,
        signal_scale: float = 1.0,
    ):
        self.path = path
        self.derivation = derivation
        self.chunk_seconds = chunk_seconds
        self.signal_scale = signal_scale

    def __iter__(self) -> Iterator[np.ndarray]:
        reader = pyedflib.EdfReader(str(self.path))
        try:
            labels = [label.strip() for label in reader.getSignalLabels()]
            signal_index = labels.index(self.derivation.signal)
            reference_index = (
                labels.index(self.derivation.reference)
                if self.derivation.reference is not None
                else None
            )
            sample_rate = float(reader.getSampleFrequency(signal_index))
            if reference_index is not None:
                reference_rate = float(reader.getSampleFrequency(reference_index))
                if not math.isclose(sample_rate, reference_rate):
                    raise ValueError("Signal and reference sample rates differ")
            epoch_samples = round(sample_rate * 30)
            chunk_samples = max(1, round(sample_rate * self.chunk_seconds))
            total_samples = reader.getNSamples()[signal_index]
            pending = np.empty(0, dtype=np.float64)
            for start in range(0, total_samples, chunk_samples):
                count = min(chunk_samples, total_samples - start)
                values = reader.readSignal(signal_index, start, count)
                if reference_index is not None:
                    values = values - reader.readSignal(reference_index, start, count)
                values *= self.signal_scale
                pending = np.concatenate((pending, values))
                while pending.size >= epoch_samples:
                    yield pending[:epoch_samples]
                    pending = pending[epoch_samples:]
        finally:
            reader.close()


class TrainNidraPreprocessor:
    """Exact causal 0.3–35 Hz and linear resampling used by the Rust core."""

    def __init__(self, sample_rate: float):
        self.sample_rate = sample_rate
        self.low_state = 0.0
        self.high_previous_x = 0.0
        self.high_previous_y = 0.0

    def process(self, epoch: np.ndarray) -> np.ndarray:
        centered = np.nan_to_num(epoch - np.nanmedian(epoch), nan=0.0)
        dt = 1.0 / self.sample_rate
        hp_rc = 1.0 / (2.0 * math.pi * 0.3)
        hp_alpha = hp_rc / (hp_rc + dt)
        lp_rc = 1.0 / (2.0 * math.pi * 35.0)
        lp_alpha = dt / (lp_rc + dt)
        filtered = np.empty_like(centered)
        for index, value in enumerate(centered):
            high = hp_alpha * (
                self.high_previous_y + value - self.high_previous_x
            )
            self.high_previous_x = value
            self.high_previous_y = high
            self.low_state += lp_alpha * (high - self.low_state)
            filtered[index] = self.low_state
        filtered = np.clip(filtered, -500.0, 500.0)
        source_positions = np.arange(filtered.size, dtype=np.float64)
        target_positions = np.linspace(0, filtered.size - 1, 3000)
        model_epoch = np.interp(target_positions, source_positions, filtered)
        sd = model_epoch.std()
        if sd < 1e-6:
            return np.zeros(3000, dtype=np.float32)
        return np.clip((model_epoch - model_epoch.mean()) / sd, -10, 10).astype(
            np.float32
        )


def infer_causally(session: ort.InferenceSession, epochs: list[np.ndarray]) -> np.ndarray:
    input_name = session.get_inputs()[0].name
    probabilities = []
    history: list[np.ndarray] = []
    for epoch in epochs:
        history.append(epoch)
        context = history[-20:]
        # Repeating the earliest available epoch avoids presenting artificial
        # flat-line epochs during the first 9.5 minutes of a recording.
        context = [context[0]] * (20 - len(context)) + context
        tensor = np.asarray(context, dtype=np.float32)[None, :, None, :]
        logits = session.run(None, {input_name: tensor})[0][0, -1]
        logits = logits - logits.max()
        probs = np.exp(logits)
        probabilities.append(probs / probs.sum())
    return np.asarray(probabilities)


def metrics(truth: np.ndarray, predicted: np.ndarray) -> dict[str, object]:
    matrix = confusion_matrix(
        truth, predicted, labels=np.arange(len(STAGES))
    )
    support = matrix.sum(axis=1)
    stage_recall = {
        stage: (
            round(float(matrix[index, index] / support[index]), 5)
            if support[index]
            else None
        )
        for index, stage in enumerate(STAGES)
    }
    return {
        "accuracy": round(float(accuracy_score(truth, predicted)), 5),
        "macro_f1": round(float(f1_score(truth, predicted, average="macro")), 5),
        "cohen_kappa": round(float(cohen_kappa_score(truth, predicted)), 5),
        "evaluated_epochs": int(truth.size),
        "stage_support": {
            stage: int(support[index]) for index, stage in enumerate(STAGES)
        },
        "stage_recall": stage_recall,
        "confusion_matrix": matrix.tolist(),
    }


def candidate_derivations(labels: list[str]) -> list[Derivation]:
    candidates: list[Derivation] = []
    for label in ("Fz", "Cz", "C3", "C4"):
        if label in labels:
            candidates.append(Derivation(label))
    if "M1" in labels:
        for label in ("Fz", "C3", "C4"):
            if label in labels:
                candidates.append(Derivation(label, "M1"))
    return candidates


def load_features(
    edf_path: Path,
    derivation: Derivation,
    max_epochs: int,
    chunk_seconds: float,
    signal_scale: float = 1.0,
) -> tuple[list[np.ndarray], float]:
    with pyedflib.EdfReader(str(edf_path)) as reader:
        labels = [label.strip() for label in reader.getSignalLabels()]
        sample_rate = float(reader.getSampleFrequency(labels.index(derivation.signal)))
    preprocessor = TrainNidraPreprocessor(sample_rate)
    epochs = []
    for epoch in EdfEpochStream(
        edf_path,
        derivation,
        chunk_seconds,
        signal_scale,
    ):
        epochs.append(preprocessor.process(epoch))
        if len(epochs) >= max_epochs:
            break
    return epochs, sample_rate


def optimize(args: argparse.Namespace) -> None:
    reference = load_reference(args.scoring)
    with pyedflib.EdfReader(str(args.edf)) as reader:
        labels = [label.strip() for label in reader.getSignalLabels()]
    derivations = (
        [parse_derivation(value) for value in args.derivation]
        if args.derivation
        else candidate_derivations(labels)
    )
    model_paths = args.model or sorted(args.model_dir.glob("*model.onnx"))
    results = []
    for derivation in derivations:
        features, sample_rate = load_features(
            args.edf,
            derivation,
            len(reference),
            args.chunk_seconds,
            args.signal_scale,
        )
        usable = min(len(features), len(reference))
        if usable < 2:
            continue
        split = max(1, min(usable - 1, round(usable * args.train_fraction)))
        valid_positions = np.asarray(
            [index for index, value in enumerate(reference[:usable]) if value is not None],
            dtype=np.int64,
        )
        truth = np.asarray(
            [reference[index] for index in valid_positions],
            dtype=np.int64,
        )
        selection_mask = valid_positions < split
        validation_mask = valid_positions >= split
        if not selection_mask.any() or not validation_mask.any():
            continue
        for model_path in model_paths:
            session = ort.InferenceSession(
                str(model_path), providers=["CPUExecutionProvider"]
            )
            probs = infer_causally(session, features[:usable])
            predicted = probs.argmax(axis=1)
            row = {
                "model": str(model_path),
                "derivation": derivation.label,
                "sample_rate": sample_rate,
                "epochs": usable,
                "input_signal_scale": args.signal_scale,
                "selection": metrics(
                    truth[selection_mask],
                    predicted[valid_positions[selection_mask]],
                ),
                "validation": metrics(
                    truth[validation_mask],
                    predicted[valid_positions[validation_mask]],
                ),
                "all": metrics(truth, predicted[valid_positions]),
            }
            results.append(row)
            print(
                f"{model_path.name:20s} {derivation.label:8s} "
                f"select κ={row['selection']['cohen_kappa']:.3f} "
                f"validation κ={row['validation']['cohen_kappa']:.3f}"
            )
    if not results:
        raise RuntimeError("No model/derivation candidates could be evaluated")
    best = max(
        results,
        key=lambda row: (
            row["selection"]["cohen_kappa"],
            row["selection"]["macro_f1"],
        ),
    )
    output = {
        "stage_order": STAGES,
        "train_fraction": args.train_fraction,
        "selected": best,
        "candidates": results,
    }
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(f"\nSelected {Path(best['model']).name} with {best['derivation']}")
    print(f"Report written to {args.output}")


def parse_derivation(value: str) -> Derivation:
    parts = value.split("-", 1)
    return Derivation(parts[0], parts[1] if len(parts) == 2 else None)


def replay(args: argparse.Namespace) -> None:
    derivation = parse_derivation(args.derivation)
    features, _ = load_features(
        args.edf,
        derivation,
        args.max_epochs or 10**9,
        args.chunk_seconds,
        args.signal_scale,
    )
    session = ort.InferenceSession(str(args.model), providers=["CPUExecutionProvider"])
    probabilities = infer_causally(session, features)
    started = time.monotonic()
    output = []
    for index, probs in enumerate(probabilities):
        if args.speed > 0:
            target = started + (index + 1) * 30.0 / args.speed
            time.sleep(max(0.0, target - time.monotonic()))
        stage_index = int(probs.argmax())
        row = {
            "epoch": index + 1,
            "start": index * 30.0,
            "end": (index + 1) * 30.0,
            "stage": STAGES[stage_index],
            "confidence": round(float(probs[stage_index]), 6),
            "probabilities": {
                stage: round(float(probs[i]), 6) for i, stage in enumerate(STAGES)
            },
        }
        output.append(row)
        print(json.dumps(row), flush=True)
    if args.output:
        args.output.write_text(json.dumps(output, indent=2) + "\n")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("edf", type=Path)
    common.add_argument("--chunk-seconds", type=float, default=1.0)
    common.add_argument(
        "--signal-scale",
        type=float,
        default=1.0,
        help="multiply calibrated EDF values before preprocessing (xAMP legacy: 0.01)",
    )

    optimize_parser = subparsers.add_parser("optimize", parents=[common])
    optimize_parser.add_argument("scoring", type=Path)
    optimize_parser.add_argument(
        "--model-dir",
        type=Path,
        default=Path("assets/models/tinysleepnet-supratak"),
    )
    optimize_parser.add_argument("--model", type=Path, action="append")
    optimize_parser.add_argument("--derivation", action="append", default=[])
    optimize_parser.add_argument("--train-fraction", type=float, default=0.7)
    optimize_parser.add_argument(
        "--output", type=Path, default=Path("build/sleep_scoring_optimization.json")
    )
    optimize_parser.set_defaults(func=optimize)

    replay_parser = subparsers.add_parser("replay", parents=[common])
    replay_parser.add_argument("--model", type=Path, required=True)
    replay_parser.add_argument("--derivation", default="Fz-M1")
    replay_parser.add_argument("--speed", type=float, default=0.0)
    replay_parser.add_argument("--max-epochs", type=int)
    replay_parser.add_argument("--output", type=Path)
    replay_parser.set_defaults(func=replay)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if hasattr(args, "output") and args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
    args.func(args)


if __name__ == "__main__":
    main()
