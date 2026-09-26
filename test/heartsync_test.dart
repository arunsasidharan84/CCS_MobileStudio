import 'dart:io';
import 'dart:math';

import 'package:ccs_mobile_studio/core/eeg/orbit_sample_clock.dart';
import 'package:ccs_mobile_studio/core/models/device_profile.dart';
import 'package:ccs_mobile_studio/modules/heartsync/cardiac_replay.dart';
import 'package:ccs_mobile_studio/modules/heartsync/models.dart';
import 'package:ccs_mobile_studio/modules/heartsync/cardiac_detector.dart';
import 'package:ccs_mobile_studio/modules/heartsync/adaptive_boundary_analyzer.dart';
import 'package:ccs_mobile_studio/modules/heartsync/posthoc_analyzer.dart';
import 'package:ccs_mobile_studio/modules/heartsync/trial_planner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Orbit sample clock suppresses BLE notification jitter', () {
    final clock = OrbitSampleClock();
    final start = DateTime.utc(2026, 1, 1);
    final first = clock.firstTimestampForBatch(
      packetArrival: start.add(const Duration(milliseconds: 48)),
      sampleCount: 4,
      sampleRate: 62.5,
    );
    final second = clock.firstTimestampForBatch(
      // This notification is 30 ms late, but samples remain nearly uniform.
      packetArrival: start.add(const Duration(milliseconds: 142)),
      sampleCount: 4,
      sampleRate: 62.5,
    );
    expect(first, start);
    expect(second.difference(first).inMilliseconds, 66);
  });

  test('cardiac replay reads simultaneous PPG, ECG, and markers', () async {
    final directory = await Directory.systemTemp.createTemp('heartsync_test_');
    final file = File('${directory.path}/both.csv');
    try {
      await file.writeAsString(
        'timestamp_utc,PPG,ECG,marker\n'
        '2026-01-01T00:00:00.000Z,1.0,-2.0,0\n'
        '2026-01-01T00:00:00.016Z,1.2,-1.5,11\n',
      );
      final replay = await HeartSyncCardiacReplay.load(
        file.path,
        valueColumnType: SignalType.ppg,
      );
      expect(replay, hasLength(4));
      expect(replay.map((sample) => sample.signalType).toSet(), {
        SignalType.ppg,
        SignalType.ecg,
      });
      expect(replay.last.offset, const Duration(milliseconds: 16));
      expect(replay.last.markerCode, 11);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  test('delivery probability defaults to 80% and is safely bounded', () {
    expect(const HeartSyncConfig().validated().deliveryProbability, 0.8);
    expect(
      const HeartSyncConfig(
        deliveryProbability: 2,
      ).validated().deliveryProbability,
      0.9,
    );
    expect(
      const HeartSyncConfig(
        deliveryProbability: 0.1,
      ).validated().deliveryProbability,
      0.75,
    );
    expect(
      const HeartSyncConfig(
        minimumStimulusIntervalMs: 10,
      ).validated().minimumStimulusIntervalMs,
      100,
    );
  });

  test('planner preserves 80:20 oddball ratio and balances both phases', () {
    const config = HeartSyncConfig(
      totalStimuli: 100,
      rareProportion: 0.2,
      trialsPerBlock: 25,
      blocks: 4,
    );
    final plans = HeartSyncTrialPlanner.build(config, random: Random(7));
    final rare = plans
        .where((trial) => trial.stimulus == HeartSyncStimulusKind.rare)
        .toList();
    final frequent = plans
        .where((trial) => trial.stimulus == HeartSyncStimulusKind.frequent)
        .toList();

    expect(plans, hasLength(100));
    expect(rare, hasLength(20));
    expect(frequent, hasLength(80));
    expect(
      rare.where((trial) => trial.targetPhase == CardiacPhase.systole),
      hasLength(10),
    );
    expect(
      frequent.where((trial) => trial.targetPhase == CardiacPhase.systole),
      hasLength(40),
    );
    expect(plans.last.block, 3);
  });

  test('causal PPG detector ignores the dicrotic wave', () {
    final detector = CardiacDetector(
      const HeartSyncConfig(refractoryMs: 450, ipiHistoryLength: 5),
    );
    final start = DateTime.utc(2026, 1, 1);
    final detections = <DateTime>[];
    const sampleRate = 62.5;
    for (var i = 0; i < sampleRate * 15; i++) {
      final time = i / sampleRate;
      final phase = time % 1;
      final main = 1.0 * exp(-pow((phase - 0.2) / 0.055, 2));
      final dicrotic = 0.35 * exp(-pow((phase - 0.48) / 0.08, 2));
      final detected = detector.add(
        CardiacSample(
          start.add(Duration(microseconds: (time * 1000000).round())),
          main + dicrotic,
        ),
      );
      if (detected != null) detections.add(detected);
    }
    expect(detections.length, inInclusiveRange(12, 14));
    expect(detector.meanIpiMs, closeTo(1000, 25));
  });

  test('Bayesian boundary search finds the strongest symmetric RT split', () {
    final start = DateTime.utc(2026, 1, 1);
    final trials = <HeartSyncTrialResult>[];
    final phases = <double>[5, 10, 15, 20, 30, 40, 50, 60, 70, 80, 90];
    for (var index = 0; index < phases.length; index++) {
      final phase = phases[index];
      final onset = start.add(Duration(seconds: index));
      final rt = phase <= 20 || phase >= 80 ? 800 : 400;
      trials.add(
        HeartSyncTrialResult(
            plan: HeartSyncTrialPlan(
              index: index,
              block: 0,
              stimulus: HeartSyncStimulusKind.rare,
              targetPhase: CardiacPhase.systole,
            ),
            scheduledAt: onset,
            playbackRequestedAt: onset,
            presentedAt: onset,
            estimatedIpiMs: 1000,
            realtimeOffsetPercent: phase,
          )
          ..postHocPhasePercent = phase
          ..response = HeartSyncResponse.rare
          ..responseAt = onset.add(Duration(milliseconds: rt)),
      );
    }

    final boundary = AdaptiveBoundaryAnalyzer.analyze(
      trials,
      const HeartSyncConfig(
        adaptiveOffsets: true,
        adaptiveStepPercent: 5,
        adaptiveMinTrials: 8,
      ),
      HeartSyncStimulusKind.rare,
      (trial) => trial.isCorrect,
      seed: 4,
    );

    expect(boundary, isNotNull);
    expect(boundary!.boundaryPercent, lessThanOrEqualTo(25));
    expect(boundary.metrics.ratio, greaterThan(1.5));
  });

  test(
    'functional boundary is established only with stable meaningful effect',
    () {
      final start = DateTime.utc(2026, 1, 1);
      final phases = <double>[5, 10, 15, 20, 30, 40, 50, 60, 70, 80, 85, 95];

      List<HeartSyncTrialResult> trialsFor(bool phaseEffect) => [
        for (var index = 0; index < 96; index++)
          (() {
            final phase = phases[index % phases.length];
            final onset = start.add(Duration(seconds: index));
            final periPulse = phase <= 20 || phase >= 80;
            final rt = phaseEffect && periPulse ? 800 : 400;
            return HeartSyncTrialResult(
                plan: HeartSyncTrialPlan(
                  index: index,
                  block: index ~/ 24,
                  stimulus: HeartSyncStimulusKind.rare,
                  targetPhase: CardiacPhase.systole,
                ),
                scheduledAt: onset,
                playbackRequestedAt: onset,
                presentedAt: onset,
                estimatedIpiMs: 1000,
                realtimeOffsetPercent: phase,
              )
              ..postHocPhasePercent = phase
              ..response = HeartSyncResponse.rare
              ..responseAt = onset.add(Duration(milliseconds: rt));
          })(),
      ];

      const config = HeartSyncConfig(
        adaptiveOffsets: true,
        adaptiveStepPercent: 5,
        adaptiveMinTrials: 20,
      );
      final strong = AdaptiveBoundaryAnalyzer.analyze(
        trialsFor(true),
        config,
        HeartSyncStimulusKind.rare,
        (trial) => trial.isCorrect,
        seed: 9,
      );
      final flat = AdaptiveBoundaryAnalyzer.analyze(
        trialsFor(false),
        config,
        HeartSyncStimulusKind.rare,
        (trial) => trial.isCorrect,
        seed: 9,
      );

      expect(strong, isNotNull);
      expect(strong!.isEstablished, isTrue);
      expect(strong.boundaryPercent, closeTo(20, 5));
      expect(strong.ratioLower, greaterThan(1));
      expect(flat, isNotNull);
      expect(flat!.isEstablished, isFalse);
      expect(flat.status, contains('RT effect below 5%'));
    },
  );

  test('post-hoc analysis reassigns phase from the recorded cardiac cycle', () {
    final start = DateTime.utc(2026, 1, 1);
    final samples = <CardiacSample>[];
    for (var i = 0; i < 1000; i++) {
      final milliseconds = i * 4;
      final withinCycle = milliseconds % 1000;
      final value = withinCycle == 0 ? 10.0 : 0.0;
      samples.add(
        CardiacSample(start.add(Duration(milliseconds: milliseconds)), value),
      );
    }
    HeartSyncTrialResult rareAt(int milliseconds, int rtMs) {
      final onset = start.add(Duration(milliseconds: milliseconds));
      return HeartSyncTrialResult(
          plan: const HeartSyncTrialPlan(
            index: 0,
            block: 0,
            stimulus: HeartSyncStimulusKind.rare,
            targetPhase: CardiacPhase.systole,
          ),
          scheduledAt: onset,
          playbackRequestedAt: onset,
          presentedAt: onset,
          estimatedIpiMs: 1000,
          realtimeOffsetPercent: 0,
        )
        ..response = HeartSyncResponse.rare
        ..responseAt = onset.add(Duration(milliseconds: rtMs));
    }

    final systolic = rareAt(1100, 400);
    final diastolic = rareAt(1500, 500);
    final summary = HeartSyncPostHocAnalyzer.analyze(samples, [
      systolic,
      diastolic,
    ], const HeartSyncConfig(postHocSystolicEndPercent: 35));

    expect(systolic.postHocPhase, CardiacPhase.systole);
    expect(diastolic.postHocPhase, CardiacPhase.diastole);
    expect(summary.rareSystolicMeanMs, 400);
    expect(summary.rareDiastolicMeanMs, 500);
    expect(summary.ratio, closeTo(0.8, 0.0001));
    expect(summary.deliveryRate, isNull);
  });

  test('summary reports achieved delivery per detected beat', () {
    final summary = HeartSyncPostHocAnalyzer.analyze(
      const [],
      const [],
      const HeartSyncConfig(),
      detectedBeats: 20,
    );
    expect(summary.detectedBeats, 20);
    expect(summary.deliveryRate, 0);
  });

  test('summary separates frequent correct, incorrect, and all RT ratios', () {
    final start = DateTime.utc(2026, 1, 1);
    final samples = <CardiacSample>[
      for (var i = 0; i < 1000; i++)
        CardiacSample(
          start.add(Duration(milliseconds: i * 4)),
          i % 250 == 0 ? 10 : 0,
        ),
    ];
    HeartSyncTrialResult frequentAt(
      int onsetMs,
      int rtMs,
      HeartSyncResponse response,
    ) {
      final onset = start.add(Duration(milliseconds: onsetMs));
      return HeartSyncTrialResult(
          plan: const HeartSyncTrialPlan(
            index: 0,
            block: 0,
            stimulus: HeartSyncStimulusKind.frequent,
            targetPhase: CardiacPhase.systole,
          ),
          scheduledAt: onset,
          playbackRequestedAt: onset,
          presentedAt: onset,
          estimatedIpiMs: 1000,
          realtimeOffsetPercent: 0,
        )
        ..response = response
        ..responseAt = onset.add(Duration(milliseconds: rtMs));
    }

    final summary = HeartSyncPostHocAnalyzer.analyze(samples, [
      frequentAt(1100, 400, HeartSyncResponse.frequent),
      frequentAt(1500, 500, HeartSyncResponse.frequent),
      frequentAt(2100, 600, HeartSyncResponse.rare),
      frequentAt(2500, 300, HeartSyncResponse.rare),
    ], const HeartSyncConfig());

    expect(summary.frequentCorrect.ratio, closeTo(0.8, 0.0001));
    expect(summary.frequentIncorrect.ratio, closeTo(2, 0.0001));
    expect(summary.frequentAllResponded.ratio, closeTo(1.25, 0.0001));
    expect(summary.frequentAllResponded.systolicCount, 2);
    expect(summary.frequentAllResponded.diastolicCount, 2);
  });
}
