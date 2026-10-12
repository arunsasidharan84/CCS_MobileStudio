import 'dart:async';
import 'dart:math';
import 'package:ccs_mobile_studio/core/models/device_profile.dart';
import 'package:ccs_mobile_studio/core/models/module_type.dart';
import 'package:ccs_mobile_studio/core/models/signal_stream_sample.dart';
import 'package:ccs_mobile_studio/modules/resonance/resonance_analysis.dart';
import 'package:ccs_mobile_studio/modules/resonance/resonance_engine.dart';
import 'package:flutter_test/flutter_test.dart';

List<ResonanceInterval> synthetic({
  double rate = 5.5,
  double amplitude = 60,
  double trend = 0,
  bool reject = false,
}) {
  final result = <ResonanceInterval>[];
  double t = 0;
  var i = 0;
  while (t < 120) {
    final rr = 900 + amplitude * sin(2 * pi * rate / 60 * t) + trend * t;
    t += rr / 1000;
    if (t <= 120) {
      result.add(
        ResonanceInterval(t - rr / 2000, rr, accepted: !reject || i % 5 != 0),
      );
    }
    i++;
  }
  return result;
}

ResonanceMetrics observation(
  double rate,
  double best, {
  double amplitude = 80,
}) => ResonanceMetrics(
  rate: rate,
  amplitudeMs: amplitude * exp(-pow((rate - best) / 0.8, 2) / 2),
  fitR2: 0.9,
  sdnnMs: 40,
  rmssdMs: 20,
  coverage: 1,
  acceptedFraction: 1,
  logNoise: 0.25,
  reason: null,
);
void main() {
  test('recovers irregularly sampled oscillation despite linear drift', () {
    final m = analyzeResonance(synthetic(trend: 0.8), 5.5, 120);
    expect(m.valid, isTrue);
    expect(m.amplitudeMs, closeTo(60, 1));
    expect(m.fitR2, greaterThan(0.99));
  });
  test('noise, missing beats and short epochs cannot establish a rate', () {
    expect(analyzeResonance(synthetic(reject: true), 5.5, 120).valid, isFalse);
    expect(analyzeResonance(synthetic(), 5.5, 40).valid, isFalse);
    expect(
      analyzeResonance(synthetic(amplitude: 0, trend: 1), 5.5, 120).valid,
      isFalse,
    );
    final sparse = synthetic().where((x) => x.seconds < 60).toList();
    expect(
      analyzeResonance(sparse, 5.5, 120).reason,
      'Insufficient signal coverage',
    );
    expect(analyzeResonance([], 5.5, 120).valid, isFalse);
  });
  test(
    'wrong pacing frequency has a weaker response than the true frequency',
    () {
      final data = synthetic();
      expect(
        analyzeResonance(data, 6.5, 120).amplitudeMs,
        lessThan(analyzeResonance(data, 5.5, 120).amplitudeMs / 2),
      );
    },
  );
  test(
    'adaptive posterior is normalized and invalid epochs do not update it',
    () {
      final p = ResonancePosterior();
      expect(p.nextRate(), 6);
      final before = p.marginal;
      p.update(analyzeResonance([], 6, 120));
      expect(p.observations, 0);
      expect(p.marginal, before);
      p.update(observation(6, 5.3));
      expect(p.marginal.reduce((a, b) => a + b), closeTo(1, 1e-10));
      expect(p.nextRate(), 4.5);
    },
  );
  test('information-driven assessment recovers different simulated optima', () {
    for (final optimum in [4.5, 5.2, 5.8, 6.5]) {
      final p = ResonancePosterior();
      for (var i = 0; i < 8; i++) {
        final rate = p.nextRate();
        expect(rate, inInclusiveRange(4.5, 6.5));
        p.update(observation(rate, optimum));
      }
      expect(p.bestRate, closeTo(optimum, 0.2));
      expect(p.interval95.$1, lessThanOrEqualTo(optimum + 0.1));
      expect(p.interval95.$2, greaterThanOrEqualTo(optimum - 0.1));
    }
  });
  test(
    'source selection handles mixed ECG channels without fallback to EEG',
    () {
      final controller = StreamController<SignalStreamSample>();
      final engine = ResonanceEngine(
        const ResonanceConfig(ecg: true, channel: 'ECG'),
        controller.stream,
      );
      SignalStreamSample sample({
        String device = 'xamp_l10',
        String stream = 'primary',
        List<SignalType> types = const [SignalType.eeg, SignalType.ecg],
        List<String> labels = const ['Fp1', 'ECG'],
        DateTime? at,
      }) => SignalStreamSample(
        deviceProfileId: device,
        streamId: stream,
        signalType: SignalType.eeg,
        channels: const [5, 100],
        channelLabels: labels,
        channelTypes: types,
        sampleRate: 250,
        timestamp: at ?? DateTime.now(),
        unit: 'uV',
        physicalMinimum: -3000,
        physicalMaximum: 3000,
      );
      engine.addSample(sample(device: 'orbit'));
      expect(engine.source, isNull);
      engine.addSample(sample(types: [SignalType.eeg, SignalType.eeg]));
      expect(engine.source, isNull);
      engine.addSample(sample(labels: ['Fp1', 'Fp2']));
      expect(engine.source, isNull);
      engine.addSample(
        sample(at: DateTime.now().subtract(const Duration(seconds: 10))),
      );
      expect(engine.source, isNull);
      engine.addSample(sample());
      expect(engine.source, 'xamp_l10/primary');
      engine.addSample(sample(stream: 'other'));
      expect(engine.source, 'xamp_l10/primary');
      engine.start();
      engine.stop();
      expect(engine.phase, ResonancePhase.stopped);
      expect(engine.toJson()['candidateRate'], isNull);
      expect(engine.toJson()['completedAssessment'], isFalse);
      engine.dispose();
      controller.close();
    },
  );
  test('module file tag round trips', () {
    expect(ModuleType.fromKey('RESONANCE'), ModuleType.resonance);
    expect(ModuleType.resonance.displayName, 'Resonance Breathing');
  });
  test(
    'comfortable sweep requires all rates and an independent confirmation',
    () {
      final stream = StreamController<SignalStreamSample>();
      final e = ResonanceEngine(const ResonanceConfig(), stream.stream);
      e.practice();
      expect(e.phase, ResonancePhase.idle);
      for (final rate in ResonanceEngine.conventionalRates) {
        e.rate = rate;
        e.phase = ResonancePhase.review;
        e.epochs.add(
          ResonanceEpoch(DateTime.now(), observation(rate, 5.5), false),
        );
        e.review(true);
      }
      expect(e.phase, ResonancePhase.results);
      expect(e.recommendedRate, 5.5);
      expect(e.confirmed, isFalse);
      e.practice();
      expect(e.phase, ResonancePhase.results);
      e.confirm();
      expect(e.phase, ResonancePhase.resting);
      e.phase = ResonancePhase.review;
      e.epochs.add(ResonanceEpoch(DateTime.now(), observation(5.5, 5.5), true));
      e.review(true);
      expect(e.confirmed, isTrue);
      e.practice();
      expect(e.phase, ResonancePhase.practice);
      e.stop();
      e.dispose();
      stream.close();
    },
  );
  test('uncomfortable epochs do not advance the adaptive assessment', () {
    final stream = StreamController<SignalStreamSample>();
    final e = ResonanceEngine(
      const ResonanceConfig(method: ResonanceMethod.adaptive),
      stream.stream,
    );
    e.phase = ResonancePhase.review;
    e.epochs.add(ResonanceEpoch(DateTime.now(), observation(6, 5.5), false));
    e.review(false);
    expect(e.acceptedTrials, 0);
    expect(e.posterior.observations, 0);
    expect(e.recommendedRate, isNull);
    e.retry();
    expect(e.phase, ResonancePhase.resting);
    e.dispose();
    stream.close();
  });
  test(
    'custom protocol round trips and drives sweep and quality thresholds',
    () {
      const config = ResonanceConfig(
        minRate: 4,
        maxRate: 7,
        sweepStep: 1,
        measureSeconds: 180,
        settleSeconds: 45,
        restSeconds: 120,
        practiceSeconds: 600,
        inhaleFraction: 0.4,
        minAmplitudeMs: 70,
        minCoverage: 0.95,
        minTrials: 4,
        maxTrials: 6,
        targetWidth: 0.3,
      );
      config.validate();
      final restored = ResonanceConfig.fromJson(config.toJson());
      expect(restored.toJson(), config.toJson());
      expect(restored.sweepRates, [7, 6, 5, 4]);
      expect(
        analyzeResonance(synthetic(), 5.5, 120, config: config).valid,
        isFalse,
      );
      final controller = StreamController<SignalStreamSample>();
      final e = ResonanceEngine(restored, controller.stream);
      e.start();
      expect(e.rate, 7);
      expect(e.toJson()['config'], config.toJson());
      e.stop();
      e.dispose();
      controller.close();
    },
  );
  test('cross-field validation rejects unsafe or meaningless settings', () {
    for (final config in [
      const ResonanceConfig(minRate: 7, maxRate: 5),
      const ResonanceConfig(measureSeconds: 90, minCycles: 10),
      const ResonanceConfig(minTrials: 8, maxTrials: 5),
      const ResonanceConfig(inhaleFraction: 0.9),
      const ResonanceConfig(noiseFloor: 0.5, planningNoise: 0.2),
      const ResonanceConfig(adaptiveStep: 0.5, targetWidth: 0.1),
      const ResonanceConfig(minCoverage: double.nan),
    ]) {
      expect(config.validate, throwsFormatException);
    }
  });
  test('custom adaptive range and resolution remain normalized and finite', () {
    final p = ResonancePosterior(
      config: const ResonanceConfig(
        minRate: 4,
        maxRate: 7,
        adaptiveStep: 0.25,
        targetWidth: 0.5,
      ),
    );
    for (var i = 0; i < 5; i++) {
      final rate = p.nextRate();
      expect(p.rates, contains(rate));
      p.update(observation(rate, 5.5));
    }
    expect(p.marginal.every((x) => x.isFinite), isTrue);
    expect(p.marginal.reduce((a, b) => a + b), closeTo(1, 1e-9));
    expect(p.bestRate, closeTo(5.5, 0.3));
  });
}
