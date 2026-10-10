# NeuroKit2 ECG algorithm attribution

`rust/src/hrd_ecg.rs` adapts the HRD-consumed default ECG algorithms from NeuroKit2 **0.2.12**: NeuroKit cleaning/detection, iterative Kubios/Lipponen–Tarvainen artifact correction, and PCHIP-interpolated period-to-rate calculation. The upstream MIT license is preserved in `LICENSE`; reference source hashes are recorded in `reference.json`.

The Python package is **not shipped or required by the application**. This folder contains attribution/provenance only. Default algorithms are implemented in dependency-free Rust, with golden reference fixtures under `rust/src/hrd_ecg_fixtures.rs`.

`tools/validate_hrd_neurokit.py` requires the pinned package only during development and compares outputs against the original `nk.bio_process` entry point. It also exercises all four artifact classes independently.
