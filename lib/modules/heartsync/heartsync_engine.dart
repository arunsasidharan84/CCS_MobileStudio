import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../core/eeg/acquisition_service.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/signal_stream_sample.dart';
import '../../core/services/multi_stream_lsl_service.dart';
import '../../core/services/session_manager.dart';
import 'cardiac_detector.dart';
import 'cardiac_replay.dart';
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

class HeartSyncTracePoint {
  const HeartSyncTracePoint(this.timestamp, this.value);

  final DateTime timestamp;
  final double value;
}

class HeartSyncTraceMarker {
  const HeartSyncTraceMarker({
    required this.timestamp,
    required this.code,
    required this.label,
  });

  final DateTime timestamp;
  final int code;
  final String label;
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
    _ppgDisplayFilter = _LiveCardiacFilter(
      this.config.detectionHighPassHz,
      this.config.detectionLowPassHz,
    );
    _ecgDisplayFilter = _LiveCardiacFilter(
      this.config.detectionHighPassHz,
      this.config.detectionLowPassHz,
    );
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
  final List<CardiacSample> ppgSamples = [];
  final List<CardiacSample> ecgSamples = [];
  final List<HeartSyncTracePoint> ppgTrace = [];
  final List<HeartSyncTracePoint> ecgTrace = [];
  final List<DateTime> beatTrace = [];
  final List<HeartSyncTraceMarker> markerTrace = [];
  final List<HeartSyncTrialResult> results = [];
  late final _LiveCardiacFilter _ppgDisplayFilter;
  late final _LiveCardiacFilter _ecgDisplayFilter;

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
  bool _replayCancelled = false;
  DateTime? _lastWaveformNotification;
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

  List<HeartSyncTracePoint> get visiblePpgTrace => _visibleTrace(ppgTrace);
  List<HeartSyncTracePoint> get visibleEcgTrace => _visibleTrace(ecgTrace);

  List<HeartSyncTracePoint> _visibleTrace(List<HeartSyncTracePoint> source) {
    if (source.isEmpty) return const [];
    final cutoff = source.last.timestamp.subtract(
      Duration(microseconds: (config.waveformSeconds * 1000000).round()),
    );
    var start = source.length - 1;
    while (start > 0 && source[start - 1].timestamp.isAfter(cutoff)) {
      start--;
    }
    return source.sublist(start);
  }

  Future<void> start() async {
    if (state != HeartSyncRunState.idle) return;
    state = HeartSyncRunState.calibrating;
    notifyListeners();
    try {
      // Decode/open each sound before cardiac timing starts. Source setup is
      // slow and variable on AVFoundation and must not occur at stimulus time.
      await _stimulus.prepare(config);
    } catch (exception) {
      error = 'Stimulus preparation failed: $exception';
      state = HeartSyncRunState.error;
      notifyListeners();
      return;
    }
    if (config.inputMode == HeartSyncInputMode.replayFile) {
      if (config.replayFilePath.isEmpty) {
        error = 'Choose a cardiac CSV before starting replay mode.';
        state = HeartSyncRunState.error;
        notifyListeners();
        return;
      }
      unawaited(_runReplay());
    } else {
      _deviceSub = acquisition.streamSamples.listen(_onStreamSample);
      _lslSub = multiLsl.samples.listen(_onStreamSample);
    }
    notifyListeners();
  }

  Future<void> _runReplay() async {
    try {
      final data = await HeartSyncCardiacReplay.load(
        config.replayFilePath,
        valueColumnType: config.pulseMode == HeartSyncPulseMode.ppg
            ? SignalType.ppg
            : SignalType.ecg,
      );
      final startedAt = DateTime.now();
      for (final datum in data) {
        if (_replayCancelled || state == HeartSyncRunState.completed) return;
        final timestamp = startedAt.add(datum.offset);
        final wait = timestamp.difference(DateTime.now());
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        if (_replayCancelled) return;
        _onStreamSample(
          SignalStreamSample(
            deviceProfileId: 'heartsync_replay',
            streamId: 'replay_${datum.signalType.name}',
            signalType: datum.signalType,
            channels: [datum.value],
            channelLabels: [datum.channelName],
            channelTypes: [datum.signalType],
            sampleRate: datum.signalType == SignalType.ppg ? 62.5 : 250,
            timestamp: timestamp,
            unit: datum.signalType == SignalType.ppg ? 'a.u.' : 'uV',
            physicalMinimum: -32768,
            physicalMaximum: 32767,
          ),
        );
        final marker = datum.markerCode;
        if (marker != null && marker != 0) {
          markerTrace.add(
            HeartSyncTraceMarker(
              timestamp: timestamp,
              code: marker,
              label: 'FILE_$marker',
            ),
          );
        }
      }
      if (state != HeartSyncRunState.completed) stopEarly();
    } catch (exception) {
      error = 'Cardiac replay failed: $exception';
      state = HeartSyncRunState.error;
      notifyListeners();
    }
  }

  void _onStreamSample(SignalStreamSample sample) {
    if (sample.signalType != SignalType.ppg &&
        sample.signalType != SignalType.ecg) {
      return;
    }
    if (sample.channels.isEmpty) return;
    final displayIndex = sample.channelLabels.indexWhere(
      (label) => label.trim().toLowerCase() == config.channelName.toLowerCase(),
    );
    final safeDisplayIndex = displayIndex >= 0 ? displayIndex : 0;
    if (safeDisplayIndex >= sample.channels.length) return;
    final displaySample = CardiacSample(
      sample.timestamp,
      sample.channels[safeDisplayIndex],
    );
    if (sample.signalType == SignalType.ppg) {
      ppgSamples.add(displaySample);
      ppgTrace.add(
        HeartSyncTracePoint(
          sample.timestamp,
          _ppgDisplayFilter.add(displaySample),
        ),
      );
    } else {
      ecgSamples.add(displaySample);
      ecgTrace.add(
        HeartSyncTracePoint(
          sample.timestamp,
          _ecgDisplayFilter.add(displaySample),
        ),
      );
    }
    _notifyWaveformIfDue();

    final expectedType = config.pulseMode == HeartSyncPulseMode.ppg
        ? SignalType.ppg
        : SignalType.ecg;
    final channelIndex = sample.channelLabels.indexWhere(
      (label) => label.trim().toLowerCase() == config.channelName.toLowerCase(),
    );
    if (sample.signalType != expectedType) return;
    final index = channelIndex >= 0 ? channelIndex : 0;
    if (index >= sample.channels.length) return;
    final cardiac = CardiacSample(sample.timestamp, sample.channels[index]);
    cardiacSamples.add(cardiac);
    final beat = _detector.addDetailed(cardiac);
    if (beat == null) return;
    beatTrace.add(beat.peakAt);
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
    if (_scheduleTrial(plans[_nextPlanIndex], beat)) {
      _nextPlanIndex++;
    } else {
      collisionSkippedBeats++;
      notifyListeners();
    }
  }

  void _notifyWaveformIfDue() {
    if (!config.showLiveWaveform) return;
    final now = DateTime.now();
    if (_lastWaveformNotification == null ||
        now.difference(_lastWaveformNotification!).inMilliseconds >= 100) {
      _lastWaveformNotification = now;
      notifyListeners();
    }
  }

  bool _scheduleTrial(HeartSyncTrialPlan plan, CardiacBeatDetection beat) {
    final configuredOffset = plan.targetPhase == CardiacPhase.systole
        ? config.systolicOffsetPercent
        : config.diastolicOffsetPercent;
    final offset = configuredOffset;
    final estimatedIpiMs = _detector.meanIpiMs;
    final cycleOffset = plan.targetPhase == CardiacPhase.systole
        ? 1 + offset / 100
        : offset / 100;
    // Anchor the target to the signal sample, never to callback arrival time.
    // A configured lag corrects systematic filter/fiducial bias only; variable
    // transport/dispatch latency is already represented by peakAt vs now.
    final anchor = beat.peakAt.subtract(
      Duration(milliseconds: config.detectionLagMs),
    );
    final now = DateTime.now();
    var scheduled = anchor.add(
      Duration(microseconds: (estimatedIpiMs * cycleOffset * 1000).round()),
    );
    final latestCycleOffset = plan.targetPhase == CardiacPhase.systole
        ? 1 + config.postHocSystolicEndPercent / 100
        : 1 - config.postHocSystolicEndPercent / 100;
    final latest = anchor.add(
      Duration(
        microseconds: (estimatedIpiMs * latestCycleOffset * 1000).round(),
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
    // Never turn a missed cardiac-phase target into an immediate stimulus.
    // Timer jitter of a few milliseconds is tolerated; materially late trials
    // are rejected and can be attempted on a later beat.
    const lateTolerance = Duration(milliseconds: 8);
    if (scheduled.isBefore(now.subtract(lateTolerance)) ||
        scheduled.isAfter(latest)) {
      return false;
    }
    final delayMs = max(0, scheduled.difference(now).inMicroseconds / 1000);
    final effectiveCycleOffset =
        scheduled.difference(anchor).inMicroseconds / 1000 / estimatedIpiMs;
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
          triggerPeakAt: beat.peakAt,
          peakDetectedAt: beat.detectedAt,
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
    required DateTime triggerPeakAt,
    required DateTime peakDetectedAt,
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
        triggerPeakAt: triggerPeakAt,
        peakDetectedAt: peakDetectedAt,
        targetAt: scheduled,
      );
      _lastPresentedAt = result.presentedAt;
      _pendingResponses.add(result);
      visibleStimulus = plan.stimulus;
      final visualGeneration = ++_visualGeneration;
      sessionManager.recordEvent(
        'HEARTSYNC_${plan.stimulus.name}_${plan.targetPhase.name}',
        _markerCode(plan),
        occurredAt: result.presentedAt,
      );
      markerTrace.add(
        HeartSyncTraceMarker(
          timestamp: result.presentedAt,
          code: _markerCode(plan),
          label: '${plan.stimulus.name}_${plan.targetPhase.name}',
        ),
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
      occurredAt: pending.responseAt,
    );
    markerTrace.add(
      HeartSyncTraceMarker(
        timestamp: pending.responseAt!,
        code: response == HeartSyncResponse.frequent ? 21 : 22,
        label: 'response_${response.name}',
      ),
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
    _replayCancelled = true;
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

/// One-pole 0.5–8 Hz display filter. Detection owns an independent copy so
/// rendering can never change experimental decisions.
class _LiveCardiacFilter {
  _LiveCardiacFilter(this.highPassHz, this.lowPassHz);

  final double highPassHz;
  final double lowPassHz;
  DateTime? _previousTimestamp;
  double? _previousRaw;
  double _highPassed = 0;
  double _filtered = 0;

  double add(CardiacSample sample) {
    final previousRaw = _previousRaw;
    final previousTimestamp = _previousTimestamp;
    _previousRaw = sample.value;
    _previousTimestamp = sample.timestamp;
    if (previousRaw == null) return 0;
    final dt = previousTimestamp == null
        ? 0.016
        : (sample.timestamp.difference(previousTimestamp).inMicroseconds /
                  1000000)
              .clamp(0.001, 0.05);
    final highPassRc = 1 / (2 * pi * highPassHz);
    final lowPassRc = 1 / (2 * pi * lowPassHz);
    _highPassed =
        highPassRc /
        (highPassRc + dt) *
        (_highPassed + sample.value - previousRaw);
    _filtered += dt / (lowPassRc + dt) * (_highPassed - _filtered);
    return _filtered;
  }
}
