import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../../core/models/device_profile.dart';
import '../../core/models/signal_stream_sample.dart';
import '../heartsync/cardiac_detector.dart';
import '../heartsync/models.dart';
import 'resonance_analysis.dart';
import 'resonance_config.dart';
export 'resonance_config.dart';

enum ResonancePhase {
  idle,
  waiting,
  settling,
  measuring,
  review,
  resting,
  results,
  practice,
  stopped,
}

class ResonanceEpoch {
  ResonanceEpoch(this.startedAt, this.metrics, this.confirmation);
  final DateTime startedAt;
  final ResonanceMetrics metrics;
  final bool confirmation;
  bool? comfortable;
  bool used = false;
  Map<String, Object?> toJson() => {
    'startedAt': startedAt.toIso8601String(),
    ...metrics.toJson(),
    'confirmation': confirmation,
    'comfortable': comfortable,
    'used': used,
  };
}

class ResonanceEngine extends ChangeNotifier {
  ResonanceEngine(
    this.config,
    Stream<SignalStreamSample> samples, {
    Iterable<Stream<SignalStreamSample>> additionalStreams = const [],
  }) {
    config.validate();
    posterior = ResonancePosterior(config: config);
    _resetDetector();
    for (final stream in [samples, ...additionalStreams]) {
      _subscriptions.add(
        stream.listen(
          addSample,
          onError: (Object e) {
            message = 'Sensor stream error: $e';
            if (_collecting) _interrupt();
            notifyListeners();
          },
        ),
      );
    }
  }
  final ResonanceConfig config;
  late final ResonancePosterior posterior;
  final epochs = <ResonanceEpoch>[];
  final intervalLog = <Map<String, Object?>>[];
  final events = <Map<String, Object?>>[];
  final rawSamples = <Map<String, Object?>>[];
  late CardiacDetector _detector;
  final _subscriptions = <StreamSubscription<SignalStreamSample>>[];
  double? _sampleRate;
  Timer? _ticker;
  final _clock = Stopwatch();
  final _breathClock = Stopwatch();
  DateTime? startedAt, _phaseAt, _lastSample, _lastBeat;
  String? source;
  String message = 'Connect the selected sensor, then start the assessment.';
  ResonancePhase phase = ResonancePhase.idle;
  final _intervals = <ResonanceInterval>[];
  final _recent = <double>[];
  double rate = 6.5;
  double? recommendedRate;
  double heartRate = 0;
  int remaining = 0, _index = 0, _cleanStreak = 0;
  bool confirmation = false, confirmed = false;
  static const conventionalRates = [6.5, 6.0, 5.5, 5.0, 4.5];
  bool get _collecting =>
      phase == ResonancePhase.settling || phase == ResonancePhase.measuring;
  bool get active => ![
    ResonancePhase.idle,
    ResonancePhase.stopped,
    ResonancePhase.results,
  ].contains(phase);
  bool get fresh =>
      _lastSample != null &&
      DateTime.now().difference(_lastSample!).inMilliseconds < 2000;
  double get elapsed => _clock.elapsedMicroseconds / 1e6;
  double get breathPhase =>
      (_breathClock.elapsedMicroseconds / 1e6 * rate / 60) % 1;
  int get acceptedTrials =>
      epochs.where((e) => e.used && !e.confirmation).length;
  void _resetDetector() {
    _detector = CardiacDetector(
      HeartSyncConfig(
        pulseMode: config.ecg ? HeartSyncPulseMode.ecg : HeartSyncPulseMode.ppg,
        detectionHighPassHz: config.ecg ? 5 : 0.5,
        detectionLowPassHz: config.ecg ? 25 : 5,
        refractoryMs: 300,
      ),
    );
    _lastBeat = null;
    _recent.clear();
    _cleanStreak = 0;
  }

  void _event(String name) => events.add({
    'at': DateTime.now().toIso8601String(),
    'event': name,
    'rate': rate,
    'phase': phase.name,
  });
  void start() {
    if (phase != ResonancePhase.idle) return;
    startedAt = DateTime.now();
    rate = config.method == ResonanceMethod.conventional
        ? config.sweepRates.first
        : posterior.nextRate();
    _enter(ResonancePhase.waiting);
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => tick());
  }

  void _enter(ResonancePhase next) {
    if (next == ResonancePhase.settling || next == ResonancePhase.practice) {
      _breathClock
        ..reset()
        ..start();
    }
    phase = next;
    _phaseAt = DateTime.now();
    _clock
      ..reset()
      ..start();
    remaining = switch (next) {
      ResonancePhase.settling => config.settleSeconds,
      ResonancePhase.measuring => config.measureSeconds,
      ResonancePhase.resting => config.restSeconds,
      ResonancePhase.practice => config.practiceSeconds,
      _ => 0,
    };
    _event(next.name);
    notifyListeners();
  }

  void tick() {
    if (phase == ResonancePhase.waiting && fresh && _cleanStreak >= 8) {
      message = 'Follow the circle with gentle, comfortable breaths.';
      _enter(ResonancePhase.settling);
    } else if (_collecting && !fresh) {
      message = 'Signal lost. Rest, check the sensor, and retry this rate.';
      _interrupt();
    } else if (phase == ResonancePhase.settling) {
      remaining = max(0, (config.settleSeconds - elapsed).ceil());
      if (elapsed >= config.settleSeconds) {
        _intervals.clear();
        _enter(ResonancePhase.measuring);
      }
    } else if (phase == ResonancePhase.measuring) {
      remaining = max(0, (config.measureSeconds - elapsed).ceil());
      if (elapsed >= config.measureSeconds) {
        final metrics = analyzeResonance(
          _intervals,
          rate,
          config.measureSeconds.toDouble(),
          config: config,
        );
        epochs.add(ResonanceEpoch(_phaseAt!, metrics, confirmation));
        message =
            metrics.reason ?? 'Epoch recorded. How comfortable was this pace?';
        _enter(ResonancePhase.review);
      }
    } else if (phase == ResonancePhase.resting) {
      remaining = max(0, (config.restSeconds - elapsed).ceil());
      if (elapsed >= config.restSeconds) _enter(ResonancePhase.waiting);
    } else if (phase == ResonancePhase.practice) {
      remaining = max(0, (config.practiceSeconds - elapsed).ceil());
      if (!fresh) {
        message =
            'Sensor signal unavailable; pacing continues without biofeedback.';
      } else {
        message = 'Follow the circle with gentle, comfortable breaths.';
      }
      if (elapsed >= config.practiceSeconds) _enter(ResonancePhase.results);
    }
    notifyListeners();
  }

  void addSample(SignalStreamSample s) {
    if (phase == ResonancePhase.stopped) return;
    if (s.deviceProfileId != (config.ecg ? 'xamp_l10' : 'orbit')) return;
    final i = s.channelLabels.indexWhere(
      (x) => x.trim().toLowerCase() == config.channel.trim().toLowerCase(),
    );
    if (i < 0 || i >= s.channels.length) return;
    final type = i < s.channelTypes.length ? s.channelTypes[i] : s.signalType;
    if (type != (config.ecg ? SignalType.ecg : SignalType.ppg) ||
        !s.channels[i].isFinite ||
        !s.sampleRate.isFinite ||
        s.sampleRate < (config.ecg ? 100 : 25)) {
      return;
    }
    final key = '${s.deviceProfileId}/${s.streamId}';
    if (source != null && key != source) return;
    final now = DateTime.now();
    if (now.difference(s.timestamp).inMilliseconds.abs() > 2000) return;
    if (_lastSample != null) {
      final gap = s.timestamp.difference(_lastSample!).inMicroseconds / 1e6;
      if (gap <= 0) return;
      if (gap > max(0.1, 3 / s.sampleRate) ||
          (_sampleRate != null && _sampleRate != s.sampleRate)) {
        _resetDetector();
        if (_collecting) {
          message = 'A data gap interrupted the epoch. Rest and retry.';
          _interrupt();
        }
      }
    }
    source ??= key;
    _lastSample = s.timestamp;
    _sampleRate = s.sampleRate;
    if (startedAt != null) {
      rawSamples.add({
        'at': s.timestamp.toIso8601String(),
        'value': s.channels[i],
        'sampleRate': s.sampleRate,
        'source': key,
      });
    }
    final beat = _detector.add(CardiacSample(s.timestamp, s.channels[i]));
    if (beat == null) return;
    final previous = _lastBeat;
    _lastBeat = beat;
    if (previous == null) return;
    final rr = beat.difference(previous).inMicroseconds / 1000;
    final sorted = _recent.toList()..sort();
    final median = sorted.isEmpty ? rr : sorted[sorted.length ~/ 2];
    // Conservative outlier gate; avoid rejecting the normal large RSA of slow breathing.
    final accepted =
        rr >= 300 &&
        rr <= 2000 &&
        (_recent.length < 5 ||
            (rr - median).abs() < median * config.outlierFraction);
    if (accepted) {
      _recent.add(rr);
      if (_recent.length > 9) _recent.removeAt(0);
      _cleanStreak++;
      heartRate = 60000 / rr;
    } else {
      _cleanStreak = 0;
    }
    if (startedAt != null) {
      intervalLog.add({
        'at': beat.toIso8601String(),
        'intervalMs': rr,
        'accepted': accepted,
        'phase': phase.name,
        'rate': rate,
      });
    }
    if (phase == ResonancePhase.measuring &&
        previous.isAfter(_phaseAt!) &&
        beat.difference(_phaseAt!).inMicroseconds <=
            config.measureSeconds * 1000000) {
      final seconds =
          beat.difference(_phaseAt!).inMicroseconds / 1e6 - rr / 2000;
      _intervals.add(ResonanceInterval(seconds, rr, accepted: accepted));
    }
  }

  void _interrupt() {
    _event('epoch_discarded');
    _intervals.clear();
    _resetDetector();
    _enter(ResonancePhase.review);
  }

  // Review follows measuring, so identify pending feedback explicitly by null comfort.
  ResonanceEpoch? get pending =>
      epochs.isNotEmpty && epochs.last.comfortable == null ? epochs.last : null;
  void review(bool comfortable) {
    if (phase != ResonancePhase.review) return;
    final epoch = pending;
    if (epoch == null) {
      retry();
      return;
    }
    epoch.comfortable = comfortable;
    epoch.used = comfortable && epoch.metrics.valid;
    if (!epoch.used) {
      message = comfortable
          ? 'Check signal quality before retrying.'
          : 'Rest and breathe naturally. Retry only when comfortable.';
      notifyListeners();
      return;
    }
    if (confirmation) {
      final discovery = epochs.where((e) => e.used && !e.confirmation).toList();
      final reference = discovery.reduce(
        (a, b) => (a.metrics.rate - rate).abs() < (b.metrics.rate - rate).abs()
            ? a
            : b,
      );
      final ratio = epoch.metrics.amplitudeMs / reference.metrics.amplitudeMs;
      confirmed =
          ratio >= config.confirmRatioMin && ratio <= config.confirmRatioMax;
      message = confirmed
          ? 'Repeatable cardiac response at this candidate pace.'
          : 'Confirmation differs from assessment. Repeat the assessment on another occasion.';
      _enter(ResonancePhase.results);
      return;
    }
    if (config.method == ResonanceMethod.adaptive) {
      posterior.update(epoch.metrics);
    }
    _index++;
    final bounds = posterior.interval95;
    final finished = config.method == ResonanceMethod.conventional
        ? _index >= config.sweepRates.length
        : _index >= config.maxTrials ||
              (_index >= config.minTrials &&
                  bounds.$2 - bounds.$1 <= config.targetWidth);
    if (finished) {
      final valid = epochs.where((e) => e.used).toList()
        ..sort(
          (a, b) => b.metrics.amplitudeMs.compareTo(a.metrics.amplitudeMs),
        );
      recommendedRate = config.method == ResonanceMethod.conventional
          ? valid.first.metrics.rate
          : posterior.bestRate;
      message = 'Candidate pace found. Confirm with a fresh measurement epoch.';
      _enter(ResonancePhase.results);
    } else {
      rate = config.method == ResonanceMethod.conventional
          ? config.sweepRates[_index]
          : posterior.nextRate();
      _enter(ResonancePhase.resting);
    }
  }

  void retry() {
    if (phase != ResonancePhase.review) return;
    if (pending != null) pending!.comfortable = false;
    _resetDetector();
    _enter(ResonancePhase.resting);
  }

  void confirm() {
    if (phase != ResonancePhase.results ||
        recommendedRate == null ||
        confirmed) {
      return;
    }
    rate = recommendedRate!;
    confirmation = true;
    _resetDetector();
    _enter(ResonancePhase.resting);
  }

  void practice() {
    if (phase != ResonancePhase.results || !confirmed) return;
    rate = recommendedRate!;
    _enter(ResonancePhase.practice);
  }

  void stop() {
    if (phase == ResonancePhase.stopped) return;
    _event('stop');
    _ticker?.cancel();
    _clock.stop();
    _breathClock.stop();
    phase = ResonancePhase.stopped;
    notifyListeners();
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'startedAt': startedAt?.toIso8601String(),
    'config': config.toJson(),
    'source': source,
    'channel': config.channel,
    'status': phase.name,
    'completedAssessment': recommendedRate != null,
    'candidateRate': recommendedRate,
    'confirmed': confirmed,
    'respirationMeasured': false,
    'interpretation':
        'Cardiac-response candidate; breathing adherence and baroreflex resonance unverified',
    'adaptiveExperimental': config.method == ResonanceMethod.adaptive,
    'posterior': config.method == ResonanceMethod.adaptive
        ? {
            'rates': posterior.rates,
            'probabilities': posterior.marginal,
            'interval95': [posterior.interval95.$1, posterior.interval95.$2],
          }
        : null,
    'epochs': epochs.map((e) => e.toJson()).toList(),
    'events': events,
  };
  @override
  void dispose() {
    _ticker?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }
}
