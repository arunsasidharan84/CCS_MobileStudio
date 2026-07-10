import 'dart:async';
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
  AuditoryStimService({required this.alertService});

  final AlertService alertService;

  // Configuration settings
  bool _enabled = false;
  SleepStage _targetStage = SleepStage.n3;
  double _minProbability = 0.50;
  int _stableDurationSecs = 30;
  int _maxDurationSecs = 10;
  int _intervalSecs = 2;
  int _refractorySecs = 60;
  String _stimType = 'beep'; // 'beep' or 'mp3'

  // State machine tracking
  String _statusText = 'Idle (Disabled)';
  bool _isStimulating = false;
  int _consecutiveTargetEpochs = 0;
  DateTime? _lastStimEndTime;
  int _totalStimBursts = 0;
  Timer? _burstTimer;

  bool get enabled => _enabled;
  SleepStage get targetStage => _targetStage;
  double get minProbability => _minProbability;
  int get stableDurationSecs => _stableDurationSecs;
  int get maxDurationSecs => _maxDurationSecs;
  int get intervalSecs => _intervalSecs;
  int get refractorySecs => _refractorySecs;
  String get stimType => _stimType;
  String get statusText => _statusText;
  bool get isStimulating => _isStimulating;
  int get totalStimBursts => _totalStimBursts;

  void setEnabled(bool val) {
    if (_enabled == val) return;
    _enabled = val;
    if (!_enabled) {
      _stopStimulation('Idle (Disabled)');
    } else {
      _statusText = 'Monitoring stage (${_targetStage.label})...';
    }
    notifyListeners();
  }

  void setTargetStage(SleepStage stage) {
    _targetStage = stage;
    _consecutiveTargetEpochs = 0;
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
    _refractorySecs = secs.clamp(10, 600);
    notifyListeners();
  }

  /// Process a new 30-second sleep epoch score from [SleepPipeline].
  void onNewScore(SleepScoreResult score) {
    if (!_enabled) return;

    // Check if currently in refractory period
    if (_lastStimEndTime != null) {
      final elapsedSinceRefractory = DateTime.now().difference(_lastStimEndTime!).inSeconds;
      if (elapsedSinceRefractory < _refractorySecs) {
        final remaining = _refractorySecs - elapsedSinceRefractory;
        _statusText = 'Refractory period (${remaining}s remaining)';
        notifyListeners();
        return;
      }
    }

    final prob = _getProbabilityForStage(score, _targetStage);
    final isTarget = score.stage == _targetStage && prob >= _minProbability;

    if (isTarget) {
      _consecutiveTargetEpochs++;
      final accumulatedSecs = _consecutiveTargetEpochs * 30; // each epoch is 30s
      if (accumulatedSecs >= _stableDurationSecs && !_isStimulating) {
        _startStimulation();
      } else if (!_isStimulating) {
        _statusText = 'Target stable for ${accumulatedSecs}s / ${_stableDurationSecs}s';
        notifyListeners();
      }
    } else {
      if (_consecutiveTargetEpochs > 0 && !_isStimulating) {
        _consecutiveTargetEpochs = 0;
        _statusText = 'Target stage lost • Monitoring...';
        notifyListeners();
      }
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

    int elapsedBurstSecs = 0;
    _burstTimer?.cancel();
    _burstTimer = Timer.periodic(Duration(seconds: _intervalSecs), (timer) {
      if (!_enabled || !_isStimulating) {
        timer.cancel();
        return;
      }
      alertService.playBeep();
      elapsedBurstSecs += _intervalSecs;
      if (elapsedBurstSecs >= _maxDurationSecs) {
        timer.cancel();
        _stopStimulation('Refractory period (${_refractorySecs}s)');
        _lastStimEndTime = DateTime.now();
      }
    });
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
    super.dispose();
  }
}
