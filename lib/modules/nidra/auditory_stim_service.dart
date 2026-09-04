import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../../core/models/sleep_score.dart';
import '../../core/services/alert_service.dart';

/// Auditory Closed-Loop Stimulation (ACLS) service for Train NIDRA.
///
/// Monitors incoming sleep staging scores ([SleepScoreResult]). When the target
/// stage (e.g. N2 or N3 slow-wave sleep) is stably detected for a configurable
/// duration and exceeds a minimum confidence threshold, it triggers periodic acoustic
/// stimulation (short system beeps or custom audio bursts) to enhance slow-wave
/// activity or induce lucid dreaming protocols.
class AuditoryStimService extends ChangeNotifier {
  AuditoryStimService({required this.alertService, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final AlertService alertService;
  final DateTime Function() _now;

  // Configuration settings
  bool _enabled = false;
  SleepStage _targetStage = SleepStage.n3;
  double _minProbability = 0.50;
  int _stableDurationSecs = 30;
  int _maxDurationSecs = 10;
  int _intervalSecs = 2;
  int _refractorySecs = 60;
  String _mode = 'automatic';
  bool _notifyBeep = true;
  bool _notifyFlash = true;
  int _notificationIntervalSecs = 5;
  String _stimType = 'beep'; // system beep, generated tone, or audio file
  double _toneFrequencyHz = 1000;
  int _toneDurationMs = 300;
  String _audioFilePath = '';
  double _volume = 0.85;
  final AudioPlayer _audioPlayer = AudioPlayer()
    ..setReleaseMode(ReleaseMode.stop);
  final Map<String, Uint8List> _toneCache = {};

  // State machine tracking
  String _statusText = 'Idle (Disabled)';
  bool _isStimulating = false;
  DateTime? _conditionStartedAt;
  DateTime? _snoozedUntil;
  DateTime? _detectionPulseUntil;
  DateTime? _lastNotificationAt;
  bool _conditionMet = false;
  bool _notificationActive = false;
  bool _flashOn = false;
  DateTime? _lastStimEndTime;
  int _totalStimBursts = 0;
  Timer? _burstTimer;
  Timer? _conditionTimer;

  bool get enabled => _enabled;
  SleepStage get targetStage => _targetStage;
  double get minProbability => _minProbability;
  int get stableDurationSecs => _stableDurationSecs;
  int get maxDurationSecs => _maxDurationSecs;
  int get intervalSecs => _intervalSecs;
  int get refractorySecs => _refractorySecs;
  String get mode => _mode;
  bool get notifyBeep => _notifyBeep;
  bool get notifyFlash => _notifyFlash;
  int get notificationIntervalSecs => _notificationIntervalSecs;
  String get stimType => _stimType;
  double get toneFrequencyHz => _toneFrequencyHz;
  int get toneDurationMs => _toneDurationMs;
  String get audioFilePath => _audioFilePath;
  double get volume => _volume;
  String get statusText => _statusText;
  bool get isStimulating => _isStimulating;
  int get totalStimBursts => _totalStimBursts;
  bool get conditionActive => _conditionStartedAt != null;
  bool get conditionMet => _conditionMet;
  bool get notificationActive => _notificationActive;
  bool get flashOn => _flashOn;
  int get conditionElapsedSecs => _conditionStartedAt == null
      ? 0
      : _now().difference(_conditionStartedAt!).inSeconds.clamp(0, 86400);
  int get refractoryRemainingSecs {
    final until = _snoozedUntil;
    if (until != null) {
      return until.difference(_now()).inSeconds.clamp(0, 86400);
    }
    final ended = _lastStimEndTime;
    if (ended == null) return 0;
    return (_refractorySecs - _now().difference(ended).inSeconds).clamp(
      0,
      _refractorySecs,
    );
  }

  void setEnabled(bool val) {
    if (_enabled == val) return;
    _enabled = val;
    if (!_enabled) {
      _resetCondition();
      _stopStimulation('Idle (Disabled)');
    } else {
      _statusText = 'Monitoring stage (${_targetStage.label})...';
    }
    notifyListeners();
  }

  void setTargetStage(SleepStage stage) {
    _targetStage = stage;
    _resetCondition();
    notifyListeners();
  }

  void setMode(String value) {
    if (!const ['automatic', 'manual'].contains(value)) return;
    _mode = value;
    _resetCondition();
    _statusText = _enabled
        ? 'Monitoring stage (${_targetStage.label})...'
        : 'Idle (Disabled)';
    notifyListeners();
  }

  void setNotifyBeep(bool value) {
    _notifyBeep = value;
    notifyListeners();
  }

  void setNotifyFlash(bool value) {
    _notifyFlash = value;
    if (!value) _flashOn = false;
    notifyListeners();
  }

  void setNotificationInterval(int seconds) {
    _notificationIntervalSecs = seconds.clamp(1, 60);
    notifyListeners();
  }

  void setStimType(String value) {
    if (!const ['beep', 'tone', 'audio'].contains(value)) return;
    _stimType = value;
    notifyListeners();
  }

  void setToneFrequency(double value) {
    _toneFrequencyHz = value.clamp(100, 8000);
    notifyListeners();
  }

  void setToneDuration(int value) {
    _toneDurationMs = value.clamp(20, 5000);
    notifyListeners();
  }

  void setAudioFilePath(String value) {
    _audioFilePath = value;
    notifyListeners();
  }

  void setVolume(double value) {
    _volume = value.clamp(0, 1);
    notifyListeners();
  }

  void configure({
    required bool enabled,
    required SleepStage targetStage,
    required String stimType,
    required double toneFrequencyHz,
    required int toneDurationMs,
    required String audioFilePath,
    required double volume,
    required double minProbability,
    required int stableDurationSecs,
    required int maxDurationSecs,
    required int intervalSecs,
    required int refractorySecs,
    required String mode,
    required bool notifyBeep,
    required bool notifyFlash,
    required int notificationIntervalSecs,
  }) {
    _enabled = enabled;
    _targetStage = targetStage;
    _stimType = const ['beep', 'tone', 'audio'].contains(stimType)
        ? stimType
        : 'tone';
    _toneFrequencyHz = toneFrequencyHz.clamp(100, 8000);
    _toneDurationMs = toneDurationMs.clamp(20, 5000);
    _audioFilePath = audioFilePath;
    _volume = volume.clamp(0, 1);
    _minProbability = minProbability.clamp(0.1, 1);
    _stableDurationSecs = stableDurationSecs.clamp(5, 300);
    _maxDurationSecs = maxDurationSecs.clamp(2, 60);
    _intervalSecs = intervalSecs.clamp(1, 10);
    _refractorySecs = refractorySecs.clamp(10, 3600);
    _mode = const ['automatic', 'manual'].contains(mode) ? mode : 'automatic';
    _notifyBeep = notifyBeep;
    _notifyFlash = notifyFlash;
    _notificationIntervalSecs = notificationIntervalSecs.clamp(1, 60);
    _statusText = enabled
        ? 'Monitoring stage (${_targetStage.label})...'
        : 'Idle (Disabled)';
    notifyListeners();
  }

  void setMinProbability(double val) {
    _minProbability = val.clamp(0.1, 1.0);
    notifyListeners();
  }

  void setStableDuration(int secs) {
    _stableDurationSecs = secs.clamp(5, 300);
    notifyListeners();
  }

  void setMaxDuration(int secs) {
    _maxDurationSecs = secs.clamp(2, 60);
    notifyListeners();
  }

  void setInterval(int secs) {
    _intervalSecs = secs.clamp(1, 10);
    notifyListeners();
  }

  void setRefractory(int secs) {
    _refractorySecs = secs.clamp(10, 3600);
    notifyListeners();
  }

  /// Process a new 30-second sleep epoch score from [SleepPipeline].
  void onNewScore(SleepScoreResult score) {
    if (!_enabled) return;

    // Do not stimulate from an epoch dominated by clipped, disconnected, or
    // otherwise implausible samples. Such epochs can produce a confident class
    // from the model even though the physiological input is unreliable.
    if (!score.isReliable) {
      _resetCondition();
      if (!_isStimulating) {
        _statusText =
            'Poor signal (${(score.artifactRatio * 100).round()}% artifact)';
        notifyListeners();
      }
      return;
    }

    if (_isInQuietPeriod) {
      _resetCondition();
      _statusText = _snoozedUntil != null
          ? 'Notifications snoozed (${refractoryRemainingSecs}s)'
          : 'Post-stimulation refractory (${refractoryRemainingSecs}s)';
      notifyListeners();
      return;
    }

    final prob = _getProbabilityForStage(score, _targetStage);
    final isTarget = score.stage == _targetStage && prob >= _minProbability;

    if (isTarget) {
      _beginConditionIfNeeded(prob);
    } else {
      final wasActive = conditionActive || _notificationActive;
      _resetCondition();
      if (_isStimulating) {
        _stopStimulation('Target stage lost • Monitoring...');
      } else if (wasActive) {
        _statusText = 'Target stage lost • Monitoring...';
        notifyListeners();
      }
    }
  }

  bool get _isInQuietPeriod {
    final now = _now();
    if (_snoozedUntil != null) {
      if (now.isBefore(_snoozedUntil!)) return true;
      _snoozedUntil = null;
    }
    return _lastStimEndTime != null &&
        now.difference(_lastStimEndTime!).inSeconds < _refractorySecs;
  }

  void _beginConditionIfNeeded(double probability) {
    if (_conditionStartedAt != null || _isStimulating) return;
    final now = _now();
    _conditionStartedAt = now;
    _conditionMet = false;
    _notificationActive = false;
    _lastNotificationAt = null;
    _detectionPulseUntil = now.add(const Duration(seconds: 2));
    _flashOn = _notifyFlash;
    _statusText =
        '${_targetStage.label} detected '
        '(${(probability * 100).round()}%) • stable 0/$_stableDurationSecs s';
    if (_notifyBeep) unawaited(alertService.playBeep());
    _startConditionTimer();
    notifyListeners();
  }

  void _startConditionTimer() {
    _conditionTimer?.cancel();
    _conditionTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _updateConditionClock(),
    );
  }

  void _updateConditionClock() {
    if (!_enabled || _conditionStartedAt == null || _isInQuietPeriod) {
      if (_isInQuietPeriod) _resetCondition();
      notifyListeners();
      return;
    }
    final now = _now();
    final elapsed = conditionElapsedSecs;
    if (elapsed < _stableDurationSecs) {
      _flashOn =
          _notifyFlash &&
          _detectionPulseUntil != null &&
          now.isBefore(_detectionPulseUntil!);
      _statusText =
          '${_targetStage.label} detected • stable '
          '$elapsed/$_stableDurationSecs s';
      notifyListeners();
      return;
    }

    _conditionMet = true;
    if (_mode == 'automatic') {
      _resetCondition(keepStatus: true);
      _startStimulation();
      return;
    }

    _notificationActive = true;
    _flashOn = _notifyFlash && !_flashOn;
    _statusText =
        'READY • ${_targetStage.label} stable for ${elapsed}s '
        '• manual stimulus';
    if (_notifyBeep &&
        (_lastNotificationAt == null ||
            now.difference(_lastNotificationAt!).inSeconds >=
                _notificationIntervalSecs)) {
      _lastNotificationAt = now;
      unawaited(alertService.playBeep());
    }
    notifyListeners();
  }

  /// Silences manual guidance and blocks another condition/stimulation for
  /// the configured refractory period.
  void snooze() {
    _snoozedUntil = _now().add(Duration(seconds: _refractorySecs));
    _resetCondition(keepStatus: true);
    _statusText = 'Notifications snoozed ($_refractorySecs s)';
    notifyListeners();
  }

  void resetForScoringMontageChange() {
    _resetCondition(keepStatus: true);
    if (_isStimulating) {
      _stopStimulation('Scoring montage changed • monitoring reset');
    } else {
      _statusText = 'Scoring montage changed • monitoring reset';
      notifyListeners();
    }
  }

  void _resetCondition({bool keepStatus = false}) {
    _conditionTimer?.cancel();
    _conditionTimer = null;
    _conditionStartedAt = null;
    _conditionMet = false;
    _notificationActive = false;
    _flashOn = false;
    _detectionPulseUntil = null;
    _lastNotificationAt = null;
    if (!keepStatus && _enabled && !_isStimulating) {
      _statusText = 'Monitoring stage (${_targetStage.label})...';
    }
  }

  double _getProbabilityForStage(SleepScoreResult score, SleepStage stage) {
    return switch (stage) {
      SleepStage.wake => score.probWake,
      SleepStage.n1 => score.probN1,
      SleepStage.n2 => score.probN2,
      SleepStage.n3 => score.probN3,
      SleepStage.rem => score.probREM,
    };
  }

  void _startStimulation() {
    _isStimulating = true;
    _statusText = 'STIMULATING (${_targetStage.label} active)';
    _totalStimBursts++;
    notifyListeners();

    var elapsedBurstSecs = 0;
    _burstTimer?.cancel();
    unawaited(_playStimulus());
    _burstTimer = Timer.periodic(Duration(seconds: _intervalSecs), (timer) {
      if (!_enabled || !_isStimulating) {
        timer.cancel();
        return;
      }
      unawaited(_playStimulus());
      elapsedBurstSecs += _intervalSecs;
      if (elapsedBurstSecs >= _maxDurationSecs) {
        timer.cancel();
        _stopStimulation('Refractory period (${_refractorySecs}s)');
        _lastStimEndTime = _now();
      }
    });
  }

  Future<void> testStimulus() => _playStimulus();

  Future<void> _playStimulus() async {
    try {
      await _playStimulusUnchecked();
    } catch (error) {
      _statusText = 'Could not play stimulus: $error';
      notifyListeners();
    }
  }

  Future<void> _playStimulusUnchecked() async {
    if (_stimType == 'audio') {
      if (_audioFilePath.isEmpty || !await File(_audioFilePath).exists()) {
        _statusText = 'Audio file missing — choose it again on this device';
        notifyListeners();
        return;
      }
      await _audioPlayer.setVolume(_volume);
      await _audioPlayer.play(DeviceFileSource(_audioFilePath));
      return;
    }
    if (_stimType == 'tone') {
      final key = '$_toneFrequencyHz:$_toneDurationMs';
      final bytes = _toneCache.putIfAbsent(
        key,
        () => _wavTone(_toneFrequencyHz, _toneDurationMs),
      );
      await _audioPlayer.setVolume(_volume);
      await _audioPlayer.play(BytesSource(bytes));
      return;
    }
    await alertService.playBeep();
  }

  Uint8List _wavTone(double frequency, int durationMs) {
    const sampleRate = 44100;
    final count = (sampleRate * durationMs / 1000).round();
    final dataSize = count * 2;
    final bytes = ByteData(44 + dataSize);
    void text(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        bytes.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    text(0, 'RIFF');
    bytes.setUint32(4, 36 + dataSize, Endian.little);
    text(8, 'WAVE');
    text(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little);
    bytes.setUint16(20, 1, Endian.little);
    bytes.setUint16(22, 1, Endian.little);
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little);
    bytes.setUint16(32, 2, Endian.little);
    bytes.setUint16(34, 16, Endian.little);
    text(36, 'data');
    bytes.setUint32(40, dataSize, Endian.little);
    final ramp = math.min(220, count ~/ 4);
    for (var i = 0; i < count; i++) {
      final envelope = math.min(
        1.0,
        math.min(i / math.max(1, ramp), (count - i) / math.max(1, ramp)),
      );
      final value =
          (math.sin(2 * math.pi * frequency * i / sampleRate) *
                  envelope *
                  0.65 *
                  32767)
              .round();
      bytes.setInt16(44 + i * 2, value, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }

  void _stopStimulation(String nextStatus) {
    _burstTimer?.cancel();
    _burstTimer = null;
    _isStimulating = false;
    _statusText = nextStatus;
    notifyListeners();
  }

  @override
  void dispose() {
    _burstTimer?.cancel();
    _conditionTimer?.cancel();
    unawaited(_audioPlayer.dispose());
    super.dispose();
  }
}
