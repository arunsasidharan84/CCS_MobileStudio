# Release Notes — CCS Mobile Studio

## Version 1.0.9 (Build 10) — October 2026

### Highlights
- **Orbit EEG + PPG mode for HEP**: Native PPG pulse peaks mark cardiac events; AF7 and AF8 produce independent live HEP estimates with real-time quality checks and artifact rejection. Exports both frontal channels and pulse timestamps as PPG pulse-locked session data.
- **Heart Rate Detection (HRD) Module**: Native NeuroKit2 0.2.12 ECG branch in Rust with verified R-peak detection, iterative artifact correction, and continuous rate interpolation.
- **Automatic update prompts & macOS recovery**: Deferred update dialogs during recordings, background notification badges, and one-tap installs.

---

## Version 1.0.8 (Build 9) — October 2026

### Highlights
- **Automatic update prompts**: SleepStudio-style startup discovery and foreground/resume checks, with prompts deferred during tasks and recordings. Existing download/install/restart flow remains one click, with recording safeguards and honest checksum status. See [update distribution setup](docs/auto_updates.md).
- **Heartbeat Evoked Potential (HEP) Module**: Five-minute live resting EEG + ECG collection from a synchronized stream, causal bandpass filtering, online R-peak detection, artifact rejection, real-time HEP waveform visualization with SEM, midpoint-RR pseudotrial control comparison, and session JSON export.
- **Heart Rate Detection (HRD) Module**: Port of the Bayesian marginal-Psi interoceptive heart-rate discrimination task (`orbit_HRD`). Dual-sensor support for xAMP-L10 (native NeuroKit2 0.2.12 pipeline) and Orbit (custom PPG pipeline). Rust-accelerated numerical backend, procedural audio feedback, visual feedback mode, configurable catch trials, and multi-format reports (CSV, JSON, SVG, PDF).
- **Parity & Architecture**: Rust native library extension (`rust/src/hrd.rs`) without adding external Rust or Flutter dependencies; background isolate execution keeps UI telemetry fluid at 60 FPS.
- **In-App Upgrades & macOS Gatekeeper Auto-Recovery**: Seamless update checks, background notification badges, and one-tap upgrades across Android, macOS, and Windows. On macOS, updates and local installations automatically clear Gatekeeper quarantine and re-sign with detected Apple Developer certificates.

---

### Detailed Changes

#### 1. Heartbeat Evoked Potential (HEP) Module
- **Synchronized Dual-Signal Selection**: Enables selecting distinct EEG and ECG channels from any synchronized multi-channel hardware stream (xAMP, secondary devices, or LSL).
- **Live Preprocessing Pipeline**: Adapts the reference resting HEP pipeline with causal Butterworth biquad filtering (0.5–40 Hz EEG, 1–45 Hz ECG, with a 50 Hz notch). Automatic input voltage scaling handles V, mV, and µV units to standardized µV.
- **R-Peak Detection & Artifact Gating**: Adaptive 2-second ECG local maximum detector with a 350 ms refractory window. Discontinuity detection handles signal gaps by restarting preprocessing without splicing discontinuous data.
- **Online Averaging & Control Comparison**: Real-time epoch extraction (−200 to +800 ms), linear detrending, −200 to 0 ms baseline correction, and peak-to-peak artifact rejection (1–150 µV; raw EEG < 250 µV). Computes online running mean and SEM alongside deterministic midpoint-RR pseudotrial controls (real minus control).
- **Analysis Export**: Exports structured session JSON with real and control waveforms, SEM, R-peak counts, rejection rates, heart rate metrics, and acquisition metadata.

#### 2. Heart Rate Detection (HRD) Module
- **Bayesian Marginal-Psi Algorithm**: Full Rust implementation of the 102-level stimulus grid (-50.5 to +50.5 BPM), 102x100 alpha/beta parameter space, logistic psychometric function (gamma=0, lapse=0.05), and entropy-minimizing adaptive stimulus selection.
- **Sensor Modalities**:
  - **PPG (Orbit)**: Custom bandpass filtering, Savitzky–Golay smoothing, median filtering, peak detection, and RR/IQR outlier rejection.
  - **ECG (xAMP-L10)**: Standalone SciPy fallback pipeline port (NeuroKit2 optional branch omitted in favor of self-contained native code).
- **Procedural Audio & Visual Modes**: Procedural 16-bit PCM synthesis replaces the legacy 138 MB audio library with negligible binary footprint (~31–56 KB per ABI). Visual mode provides warning bell and rate-bar display.
- **Trial Flow & Controls**: Configurable trial count, catch trial allocation (first trial catch, remainder distributed in second half with uniform offsets), response timeout, optional confidence ratings (0–9), and a deterministic 72 BPM demo simulator.
- **Comprehensive Outputs**: Produces 18-column behavioral CSV, session summary JSON, per-trial sample/diagnostic JSON, vector SVG response plots, and paginated multi-page PDF summary reports.

#### 3. Platform Integration & macOS Installation
- Added HRD and HEP to the default study run sequence on the Home Dashboard and Settings.
- Registered canonical file naming (`<subject>_HRD_<timestamp>` and `<subject>_HEP_<timestamp>`) and background file recovery.
- **macOS Gatekeeper & In-App Updater Auto-Recovery**: The in-app updater automatically strips `com.apple.quarantine` from downloaded bundles and signs them in-place with local Apple Developer certificates (`Apple Development` / `Developer ID Application`).
- **1-Click macOS Installer**: Added `tools/install_mac.sh` to install to `/Applications`, clear Gatekeeper quarantine, and re-sign seamlessly.
- **Modern Xcode 16 / macOS 12+ Support**: Updated macOS deployment target to 12.0 in project configurations and CocoaPods.
- Bumped app version to 1.0.8+9 across Flutter and package manifests.

---

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
