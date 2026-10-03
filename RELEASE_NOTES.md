# Release Notes — CCS Mobile Studio

## Version 1.0.7 (Build 8) — October 2026

### Highlights
- **Multi-Channel EDF Recording**: Preserves full multi-channel electrode configurations, authentic channel labels, 250 Hz sampling rate, and physical range calibrations across all session segments.
- **Leads-Off & Amplitude Gating**: Real-time physiological signal validation eliminates false REM scoring on disconnected or floating leads.
- **20 Hz & 50 Hz Notch Filtering**: Suppresses spurious environmental and amplifier noise artifacts.
- **Stimulus Event Logging**: Synchronized stimulus trigger markers in both EDF annotations and companion CSV logs.
- **Stimulus Sound Library & Playlist**: Interactive ACLS audio panel with folder import, sequential/random playback, reorderable cues, per-cue custom marker codes, and instant audio playback cancellation.
- **Instant BLE Discovery & GATT 133 Auto-Recovery**: Decoupled BLE scans for 0 ms cached device discovery on first attempt, plus proactive GATT cache clearing.
- **In-App Updates**: Seamless update checks, background notification badges, and one-tap package installation on Android, macOS, and Windows.

---

### Detailed Changes

#### 1. Train NIDRA: Multi-Channel EDF Saving & Calibration
- **Full Channel Capture**: Resolved an issue where EDF files only recorded the single channel designated for autoscoring. The recorder now captures all configured and active hardware channels with proper physiological labels (e.g. `Fp1`, `Fp2`, `C3`, `C4`, `O1`, `O2`).
- **Session Parameter Persistence**: `SessionManager` now retains session parameters across BLE disconnect/reconnect events, ensuring rollover segments (`_part2.edf`, etc.) maintain the correct channel count and 250 Hz sample rate without falling back to default single-channel recorder configurations.
- **Spurious 20 Hz Noise Suppression**: Added biquad notch filter support targeting the 20 Hz interference identified in recent field recordings, complementing existing 50 Hz / 60 Hz powerline notch filtering.

#### 2. Sleep Autoscoring: Leads-Off Detection & State-of-the-Art Review
- **Physiological Amplitude Gating**: Integrated signal amplitude validation in the native core (`rust/src/lib.rs`). Signals with peak-to-peak amplitudes `< 2.5 µV` (flatline / disconnected leads) or `> 400.0 µV` (gross movement / rail saturation) are classified with 100% artifact ratio and 0.0% confidence.
- **Leads-Off Status Indicator**: The sleep stage card displays an amber `LEADS OFF (Poor signal • Check leads)` banner when electrodes are floating or disconnected, completely preventing false REM stage classifications on disconnected amplifiers.
- **Real-Time Single-Channel Sleep Staging**: Confirmed TinySleepNet ONNX architecture with causal temporal context as the benchmark model for low-latency, single-channel frontal EEG classification.

#### 3. Stimulus Markers & Event Synchronization
- **Dual-Channel Event Logging**: Every stimulus presentation (automated ACLS or manual presentation) is now recorded synchronously in:
  1. The EDF annotation track via `tn_edf_push_marker`.
  2. The companion `<subject>_<MODULE>_<timestamp>_markers.csv` event log with microsecond-accurate session timestamps, stimulus types, and trigger codes.
- **Immediate Marker Flush**: Markers are written to disk immediately upon trigger generation to prevent data loss in the event of an unexpected interruption.

#### 4. ACLS Stimulus Sound Library & Audio Management
- **Sound Library Panel**: Added a dedicated panel to manage audio cues for Auditory Closed-Loop Stimulation (ACLS). Researchers can load individual audio files or import entire folders of stimuli (`.wav`, `.mp3`, `.ogg`, `.aac`, `.flac`, `.m4a`).
- **Flexible Playback Modes**: Supports both Sequential and Randomized presentation modes with real-time visual highlighting of the currently queued or playing cue.
- **Queue Reordering & Per-Cue Markers**: Experimenters can reorder cues on the fly and configure custom trigger codes for distinct words or sound categories.
- **Instant Audio Stop**: Added a prominent `■ STOP AUDIO PLAYBACK` button in the UI, enabling researchers to instantly halt long audio files or audio loops without delay.

#### 5. Bluetooth LE Reliability & GATT 133 Recovery
- **First-Attempt Device Discovery**: Separated Classic Bluetooth inquiry from BLE scanning so the Bluetooth radio is never blinded during scans. Bonded and cached amplifiers (e.g. xAMP) now populate instantly on the first scan attempt.
- **Android GATT 133 Auto-Recovery**: Implemented proactive `clearGattCache()` and exponential retry backoff on Android during device connection and disconnection cleanup, cleanly clearing stale GATT handles and preventing reconnection deadlocks.

#### 6. In-App Updates
- **Cross-Platform Upgrades**: The app can now check for updates directly from the Home Dashboard AppBar and the Settings screen.
- **Update Availability Badge**: A subtle notification badge alerts researchers when a new release is published.
- **Automatic Packaging & Installation**: Downloads the appropriate platform asset, validates checksums, and launches the native installer (Android Package Installer for APKs, atomic app bundle hot-swap for macOS, and staged replacement for Windows).
- **CI Release Automation**: Configured GitHub Actions to build and bundle Android release APKs automatically with every release.

---

### Verification & Testing
- **Flutter Test Suite**: All 64 unit and integration tests passing (`flutter test`).
- **Rust Native Core**: All 8 native unit tests passing (`cargo test`).
- **Hardware Integration**: Tested live with connected xAMP amplifier and Samsung Galaxy Tab.
