import 'dart:async';
import 'package:flutter/foundation.dart';

import '../eeg/acquisition_service.dart';
import '../eeg/edf_recorder.dart';
import '../models/eeg_sample.dart';
import '../models/module_type.dart';
import 'settings_service.dart';
import 'file_naming_service.dart';

/// Manages EDF session lifecycle across connection/reconnection events.
///
/// - Tracks session timestamp, subject, module, and current segment index.
/// - On disconnect: closes current segment, exports to Downloads.
/// - On reconnect: opens a new segment (_part2, _part3, etc.) automatically.
class SessionManager extends ChangeNotifier {
  String _subject = '';
  ModuleType _module = ModuleType.standalone;
  DateTime? _sessionStart;
  int _segmentIndex = 1;
  bool _isRecording = false;
  bool _wasRecordingBeforeDisconnect = false;

  // ── Recording timer pause/resume ───────────────────────────────────────────
  /// Total duration accumulated in previous segments (before the current pause).
  Duration _accumulatedDuration = Duration.zero;
  /// When the current running segment started (null when paused / not recording).
  DateTime? _timerSegmentStart;
  /// True while the recording timer is paused due to disconnection.
  bool _timerPaused = false;

  EdfRecorder? _recorder;
  AcquisitionService? _acq;
  SettingsService? _settings;
  StreamSubscription<EegSample>? _sampleSub;

  AcquisitionState? _lastAcqState;

  String get subject => _subject;
  ModuleType get module => _module;
  DateTime? get sessionStart => _sessionStart;
  int get segmentIndex => _segmentIndex;
  bool get isRecording => _isRecording;

  /// Actual EEG-connected recording time (pauses on disconnect, resumes on reconnect).
  Duration get currentDuration {
    if (!_isRecording) return Duration.zero;
    final running = _timerPaused || _timerSegmentStart == null
        ? Duration.zero
        : DateTime.now().difference(_timerSegmentStart!);
    return _accumulatedDuration + running;
  }

  bool get timerPaused => _timerPaused;

  String get formattedDuration {
    final d = currentDuration;
    final hrs = d.inHours.toString().padLeft(2, '0');
    final mins = (d.inMinutes % 60).toString().padLeft(2, '0');
    final secs = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hrs:$mins:$secs';
  }

  ModuleType? get activeModule => _isRecording ? _module : null;
  int get currentSegment => _segmentIndex;
  String? get lastExportPath => _recorder?.path;
  bool get isStreaming => _acq?.currentState == AcquisitionState.streaming;
  String? get currentSessionStem {
    final start = _sessionStart;
    if (start == null || _subject.isEmpty) return null;
    return FileNamingService.stem(_subject, _module, start);
  }

  // ── DI update (called by ProxyProvider) ────────────────────────────────────

  void update(
    AcquisitionService acq,
    EdfRecorder recorder,
    SettingsService settings,
  ) {
    _recorder = recorder;
    _settings = settings;

    if (_acq != acq) {
      _sampleSub?.cancel();
      _sampleSub = acq.samples.listen((sample) {
        if (_isRecording && _recorder != null) {
          _recorder!.push(sample);
        }
      });
    }

    final newState = acq.currentState;
    if (_acq != null && newState != _lastAcqState) {
      _onAcquisitionStateChanged(newState);
    }
    _acq = acq;
    _lastAcqState = newState;
  }

  // ── State transitions ──────────────────────────────────────────────────────

  void _onAcquisitionStateChanged(AcquisitionState state) {
    switch (state) {
      case AcquisitionState.disconnected:
        if (_isRecording) {
          _wasRecordingBeforeDisconnect = true;
          _pauseTimer();
          _stopCurrentSegment();
        }
      case AcquisitionState.streaming:
        if (_wasRecordingBeforeDisconnect &&
            (_settings?.autoResumeRecordingAfterReconnect ?? true)) {
          _wasRecordingBeforeDisconnect = false;
          _resumeTimer();
          _startNextSegment();
        }
      default:
        break;
    }
  }

  void _pauseTimer() {
    if (_timerPaused || !_isRecording) return;
    if (_timerSegmentStart != null) {
      _accumulatedDuration += DateTime.now().difference(_timerSegmentStart!);
      _timerSegmentStart = null;
    }
    _timerPaused = true;
    notifyListeners();
  }

  void _resumeTimer() {
    if (!_timerPaused || !_isRecording) return;
    _timerSegmentStart = DateTime.now();
    _timerPaused = false;
    notifyListeners();
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Begin a new recording session.
  Future<String?> startSession({
    String? subject,
    String? subjectId,
    required ModuleType module,
    required int channelCount,
    required int sampleRate,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
  }) async {
    await stopSession();
    _subject = FileNamingService.sanitizeSubject(
      subject ?? subjectId ?? 'ANON',
    );
    _module = module;
    _sessionStart = DateTime.now();
    _segmentIndex = 1;
    _isRecording = true;
    _wasRecordingBeforeDisconnect = false;
    _accumulatedDuration = Duration.zero;
    _timerSegmentStart = DateTime.now();
    _timerPaused = false;

    final recorder = _recorder;
    if (recorder == null) return null;

    final path = await FileNamingService.edfPath(
      _subject,
      _module,
      _sessionStart!,
      part: 1,
    );

    await recorder.startAtPath(
      path: path,
      subject: _subject,
      channelCount: channelCount,
      sampleRate: sampleRate,
      channelLabels: channelLabels,
      enabledChannels: enabledChannels,
    );

    notifyListeners();
    debugPrint('[SessionManager] Started segment 1 → $path');
    return path;
  }

  /// Stop the session entirely.
  Future<void> stopSession() async {
    if (!_isRecording) return;
    _isRecording = false;
    _wasRecordingBeforeDisconnect = false;
    _timerPaused = false;
    _timerSegmentStart = null;
    _accumulatedDuration = Duration.zero;
    await _stopCurrentSegment();
    notifyListeners();
  }

  Future<void> stopRecording() => stopSession();

  Future<String?> startRecording({
    String? subject,
    String? subjectId,
    required ModuleType module,
    required int channelCount,
    required int sampleRate,
    List<String>? channelLabels,
    List<bool>? enabledChannels,
  }) => startSession(
    subject: subject ?? subjectId,
    module: module,
    channelCount: channelCount,
    sampleRate: sampleRate,
    channelLabels: channelLabels,
    enabledChannels: enabledChannels,
  );

  void recordEvent(String label, int code) {
    _recorder?.setMarker(code);
    debugPrint('[SessionManager] Event: $label ($code)');
  }

  Future<void> _stopCurrentSegment() async {
    final recorder = _recorder;
    if (recorder == null || !recorder.isRecording) return;
    final path = await recorder.stop();
    if (path != null) {
      final start = _sessionStart;
      final stem = start == null
          ? null
          : FileNamingService.stem(_subject, _module, start);
      await FileNamingService.exportToDownloads(
        path,
        subject: _subject,
        sessionStem: stem,
      );
      debugPrint(
        '[SessionManager] Segment closed → $path (exported to Downloads)',
      );
    }
  }

  Future<void> _startNextSegment() async {
    final start = _sessionStart;
    if (start == null || _recorder == null) return;
    _segmentIndex++;

    final path = await FileNamingService.edfPath(
      _subject,
      _module,
      start,
      part: _segmentIndex,
    );

    // Get params from the recorder's previous session
    final rec = _recorder!;
    await rec.startAtPath(
      path: path,
      subject: _subject,
      channelCount: rec.channelCount,
      sampleRate: rec.sampleRate,
      channelLabels: rec.channelLabels,
      enabledChannels: rec.enabledChannels,
    );
    debugPrint('[SessionManager] Started segment $_segmentIndex → $path');
    notifyListeners();
  }

  @override
  void dispose() {
    _sampleSub?.cancel();
    super.dispose();
  }
}
