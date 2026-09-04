import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/signal_stream_sample.dart';
import '../../core/services/multi_stream_lsl_service.dart';
import '../../core/services/session_manager.dart';
import 'cardiac_detector.dart';
import 'models.dart';
import 'posthoc_analyzer.dart';
import 'stimulus_service.dart';
import 'trial_planner.dart';

enum HeartSyncRunState {
  idle,
  calibrating,
  running,
  blockBreak,
  completed,
  error,
}

class HeartSyncEngine extends ChangeNotifier {
  HeartSyncEngine({
    required HeartSyncConfig config,
    required this.acquisition,
    required this.multiLsl,
    required this.sessionManager,
    Random? random,
  }) : config = config.validated(),
       _random = random ?? Random(),
       _stimulus = HeartSyncStimulusService() {
    _deliveryPhase = _random.nextDouble();
    _detector = CardiacDetector(this.config);
    plans = HeartSyncTrialPlanner.build(this.config, random: _random);
  }

  final HeartSyncConfig config;
  final AcquisitionService acquisition;
  final MultiStreamLslService multiLsl;
  final SessionManager sessionManager;
  final Random _random;
  final HeartSyncStimulusService _stimulus;
  late final CardiacDetector _detector;
  late final List<HeartSyncTrialPlan> plans;
  final List<CardiacSample> cardiacSamples = [];
  final List<HeartSyncTrialResult> results = [];

  StreamSubscription<SignalStreamSample>? _deviceSub;
  StreamSubscription<SignalStreamSample>? _lslSub;
  final Map<int, Timer> _presentationTimers = {};
  final Map<int, DateTime> _reservedPresentationTimes = {};
  final Map<HeartSyncTrialResult, Timer> _responseTimers = {};
  Timer? _visualTimer;
  final List<HeartSyncTrialResult> _pendingResponses = [];
  int _nextPlanIndex = 0;
  int _activeBlock = 0;
  int _visualGeneration = 0;
  late final double _deliveryPhase;
  int detectedBeats = 0;
  int collisionSkippedBeats = 0;
  DateTime? _lastPresentedAt;
  HeartSyncRunState state = HeartSyncRunState.idle;
  HeartSyncStimulusKind? visibleStimulus;
  String? error;
  HeartSyncSummary? summary;

  int get trialNumber => _nextPlanIndex;
  int get totalTrials => plans.length;
  int get currentBlock => min(config.blocks, _activeBlock + 1);
  double get estimatedIpiMs => _detector.meanIpiMs;
  bool get canRespond =>
      _pendingResponses.any((trial) => trial.response == null);

  void start() {
    if (state != HeartSyncRunState.idle) return;
    state = HeartSyncRunState.calibrating;
    _deviceSub = acquisition.streamSamples.listen(_onStreamSample);
    _lslSub = multiLsl.samples.listen(_onStreamSample);
    notifyListeners();
  }

  void _onStreamSample(SignalStreamSample sample) {
    final expectedType = config.pulseMode == HeartSyncPulseMode.ppg
        ? SignalType.ppg
        : SignalType.ecg;
    final channelIndex = sample.channelLabels.indexWhere(
      (label) => label.trim().toLowerCase() == config.channelName.toLowerCase(),
    );
    if (sample.signalType != expectedType && channelIndex < 0) return;
    final index = channelIndex >= 0 ? channelIndex : 0;
    if (index >= sample.channels.length) return;
    final cardiac = CardiacSample(sample.timestamp, sample.channels[index]);
    cardiacSamples.add(cardiac);
    final pulse = _detector.add(cardiac);
    if (pulse == null) return;
    if (state == HeartSyncRunState.calibrating &&
        cardiacSamples.length >= 100) {
      state = HeartSyncRunState.running;
    }
    if (state != HeartSyncRunState.running) {
      notifyListeners();
      return;
    }
    if (_nextPlanIndex >= plans.length ||
        plans[_nextPlanIndex].block != _activeBlock) {
      notifyListeners();
      return;
    }
    detectedBeats++;
    final deliveryTarget =
        (detectedBeats * config.deliveryProbability + _deliveryPhase).floor();
    if (_nextPlanIndex >= deliveryTarget) {
      notifyListeners();
      return;
    }
    if (_scheduleTrial(plans[_nextPlanIndex])) {
      _nextPlanIndex++;
    } else {
      collisionSkippedBeats++;
      notifyListeners();
    }
  }

  bool _scheduleTrial(HeartSyncTrialPlan plan) {
    final configuredOffset = plan.targetPhase == CardiacPhase.systole
        ? config.systolicOffsetPercent
        : config.diastolicOffsetPercent;
    final offset = configuredOffset;
    final estimatedIpiMs = _detector.meanIpiMs;
    final cycleOffset = plan.targetPhase == CardiacPhase.systole
        ? 1 + offset / 100
        : offset / 100;
    final initialDelayMs = max(
      0,
      estimatedIpiMs * cycleOffset - config.detectionLagMs,
    );
    final now = DateTime.now();
    var scheduled = now.add(
      Duration(microseconds: (initialDelayMs * 1000).round()),
    );
    final latestCycleOffset = plan.targetPhase == CardiacPhase.systole
        ? 1 + config.postHocSystolicEndPercent / 100
        : 1 - config.postHocSystolicEndPercent / 100;
    final latest = now.add(
      Duration(
        microseconds:
            (max(
                      0,
                      estimatedIpiMs * latestCycleOffset -
                          config.detectionLagMs,
                    ) *
                    1000)
                .round(),
      ),
    );
    final occupied = <DateTime>[
      ..._reservedPresentationTimes.values,
      ?_lastPresentedAt,
    ]..sort();
    final minimumGap = Duration(
      // Small guard absorbs normal mobile timer jitter while preserving the
      // user-visible minimum on actual presentation timestamps.
      milliseconds: config.minimumStimulusIntervalMs + 20,
    );
    for (final other in occupied) {
      if (scheduled.difference(other).abs() < minimumGap) {
        scheduled = other.add(minimumGap);
      }
    }
    if (scheduled.isAfter(latest)) return false;
    final delayMs = max(0, scheduled.difference(now).inMicroseconds / 1000);
    final effectiveCycleOffset =
        (delayMs + config.detectionLagMs) / estimatedIpiMs;
    final effectiveOffset = plan.targetPhase == CardiacPhase.systole
        ? (effectiveCycleOffset - 1) * 100
        : effectiveCycleOffset * 100;
    _reservedPresentationTimes[plan.index] = scheduled;
    _presentationTimers[plan.index] = Timer(
      Duration(microseconds: (delayMs * 1000).round()),
      () => unawaited(
        _presentScheduledTrial(
          plan: plan,
          scheduled: scheduled,
          estimatedIpiMs: estimatedIpiMs,
          effectiveOffset: effectiveOffset,
        ),
      ),
    );
    notifyListeners();
    return true;
  }

  Future<void> _presentScheduledTrial({
    required HeartSyncTrialPlan plan,
    required DateTime scheduled,
    required double estimatedIpiMs,
    required double effectiveOffset,
  }) async {
    if (state != HeartSyncRunState.running) {
      _presentationTimers.remove(plan.index);
      _reservedPresentationTimes.remove(plan.index);
      _maybeAdvance();
      return;
    }
    try {
      final playback = await _stimulus.present(plan.stimulus, config);
      _presentationTimers.remove(plan.index);
      _reservedPresentationTimes.remove(plan.index);
      if (state != HeartSyncRunState.running) return;
      final result = HeartSyncTrialResult(
        plan: plan,
        scheduledAt: scheduled,
        playbackRequestedAt: playback.requestedAt,
        presentedAt: playback.acknowledgedAt,
        estimatedIpiMs: estimatedIpiMs,
        realtimeOffsetPercent: effectiveOffset,
      );
      _lastPresentedAt = result.presentedAt;
      _pendingResponses.add(result);
      visibleStimulus = plan.stimulus;
      final visualGeneration = ++_visualGeneration;
      sessionManager.recordEvent(
        'HEARTSYNC_${plan.stimulus.name}_${plan.targetPhase.name}',
        _markerCode(plan),
      );
      if (config.stimulusMode == HeartSyncStimulusMode.images) {
        _visualTimer = Timer(
          Duration(milliseconds: config.imageDurationMs),
          () {
            if (visualGeneration != _visualGeneration) return;
            visibleStimulus = null;
            notifyListeners();
          },
        );
      }
      _responseTimers[result] = Timer(
        Duration(milliseconds: config.responseWindowMs),
        () => _finishResult(result),
      );
      _maybeAdvance();
      notifyListeners();
    } catch (exception) {
      _presentationTimers.remove(plan.index);
      _reservedPresentationTimes.remove(plan.index);
      error = 'Stimulus playback failed: $exception';
      state = HeartSyncRunState.error;
      notifyListeners();
    }
  }

  void respond(HeartSyncResponse response) {
    HeartSyncTrialResult? pending;
    for (final candidate in _pendingResponses.reversed) {
      if (candidate.response == null) {
        pending = candidate;
        break;
      }
    }
    if (pending == null) return;
    pending.response = response;
    pending.responseAt = DateTime.now();
    sessionManager.recordEvent(
      'HEARTSYNC_RESPONSE_${response.name}',
      response == HeartSyncResponse.frequent ? 21 : 22,
    );
    _finishResult(pending);
  }

  void _finishResult(HeartSyncTrialResult result) {
    if (!_pendingResponses.remove(result)) return;
    _responseTimers.remove(result)?.cancel();
    results.add(result);
    results.sort((a, b) => a.plan.index.compareTo(b.plan.index));
    _maybeAdvance();
    notifyListeners();
  }

  void _maybeAdvance() {
    if (_presentationTimers.isNotEmpty || _pendingResponses.isNotEmpty) return;
    if (_nextPlanIndex >= plans.length) {
      _complete();
    } else if (plans[_nextPlanIndex].block > _activeBlock) {
      state = HeartSyncRunState.blockBreak;
    }
  }

  void continueBlock() {
    if (state != HeartSyncRunState.blockBreak) return;
    _activeBlock++;
    state = HeartSyncRunState.running;
    notifyListeners();
  }

  void _complete() {
    state = HeartSyncRunState.completed;
    summary = HeartSyncPostHocAnalyzer.analyze(
      cardiacSamples,
      results,
      config,
      detectedBeats: detectedBeats,
      collisionSkippedBeats: collisionSkippedBeats,
    );
    notifyListeners();
  }

  void stopEarly() {
    for (final timer in _presentationTimers.values) {
      timer.cancel();
    }
    _presentationTimers.clear();
    _reservedPresentationTimes.clear();
    for (final pending in List<HeartSyncTrialResult>.of(_pendingResponses)) {
      _finishResult(pending);
    }
    _complete();
  }

  int _markerCode(HeartSyncTrialPlan plan) {
    final stimulus = plan.stimulus == HeartSyncStimulusKind.frequent ? 1 : 2;
    final phase = plan.targetPhase == CardiacPhase.systole ? 0 : 10;
    return stimulus + phase;
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _lslSub?.cancel();
    for (final timer in _presentationTimers.values) {
      timer.cancel();
    }
    for (final timer in _responseTimers.values) {
      timer.cancel();
    }
    _visualTimer?.cancel();
    unawaited(_stimulus.dispose());
    super.dispose();
  }
}
