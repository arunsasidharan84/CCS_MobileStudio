import 'dart:math';

import 'models.dart';

class HeartSyncTrialPlanner {
  static List<HeartSyncTrialPlan> build(HeartSyncConfig raw, {Random? random}) {
    final config = raw.validated();
    final rng = random ?? Random();
    final rareCount = (config.totalStimuli * config.rareProportion)
        .round()
        .clamp(1, max(1, config.totalStimuli - 1))
        .toInt();
    final frequentCount = config.totalStimuli - rareCount;
    final conditions =
        <({HeartSyncStimulusKind stimulus, CardiacPhase phase})>[];

    void addBalanced(HeartSyncStimulusKind kind, int count) {
      final systolic = count ~/ 2;
      final diastolic = count - systolic;
      conditions.addAll(
        List.generate(
          systolic,
          (_) => (stimulus: kind, phase: CardiacPhase.systole),
        ),
      );
      conditions.addAll(
        List.generate(
          diastolic,
          (_) => (stimulus: kind, phase: CardiacPhase.diastole),
        ),
      );
    }

    addBalanced(HeartSyncStimulusKind.frequent, frequentCount);
    addBalanced(HeartSyncStimulusKind.rare, rareCount);
    conditions.shuffle(rng);

    return [
      for (var i = 0; i < conditions.length; i++)
        HeartSyncTrialPlan(
          index: i,
          block: i ~/ config.trialsPerBlock,
          stimulus: conditions[i].stimulus,
          targetPhase: conditions[i].phase,
        ),
    ];
  }
}
