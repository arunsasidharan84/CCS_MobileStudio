import 'dart:math';

import 'models.dart';

/// Stability-gated bootstrap search for a symmetric functional peri-pulse
/// boundary. Delivery timing is deliberately not changed by this analysis.
class AdaptiveBoundaryAnalyzer {
  static HeartSyncBoundarySummary? analyze(
    List<HeartSyncTrialResult> trials,
    HeartSyncConfig config,
    HeartSyncStimulusKind stimulus,
    bool Function(HeartSyncTrialResult trial) include, {
    int seed = 1,
  }) {
    final eligible = trials
        .where(
          (trial) =>
              trial.plan.stimulus == stimulus &&
              trial.reactionTimeMs != null &&
              trial.postHocPhasePercent != null &&
              include(trial),
        )
        .toList();
    if (eligible.length < max(8, config.adaptiveMinTrials)) return null;

    final allRt = eligible.map((trial) => trial.reactionTimeMs!).toList();
    final priorMean = _mean(allRt)!;
    final priorVariance = max(_variance(allRt, priorMean), 400.0);
    final minimumPerPhase = max(4, (eligible.length * 0.2).ceil());
    final candidates = <_BoundaryCandidate>[];
    for (
      var boundary = max(5.0, config.adaptiveStepPercent);
      boundary <= 45.0;
      boundary += config.adaptiveStepPercent
    ) {
      final systolic = <double>[];
      final diastolic = <double>[];
      for (final trial in eligible) {
        final percent = trial.postHocPhasePercent!;
        final target = percent <= boundary || percent >= 100 - boundary
            ? systolic
            : diastolic;
        target.add(trial.reactionTimeMs!);
      }
      if (systolic.length < minimumPerPhase ||
          diastolic.length < minimumPerPhase) {
        continue;
      }
      candidates.add(
        _BoundaryCandidate(
          boundary: boundary,
          systolic: systolic,
          diastolic: diastolic,
        ),
      );
    }
    if (candidates.isEmpty) return null;

    // Resample trials jointly so the strong correlation between nested
    // candidate boundaries is preserved. The previous implementation sampled
    // every candidate independently, which exaggerated confidence and always
    // produced a winner even when RT was essentially phase-independent.
    final random = Random(seed);
    const draws = 2000;
    final wins = List<int>.filled(candidates.length, 0);
    var validDraws = 0;
    for (var draw = 0; draw < draws; draw++) {
      final resampled = [
        for (var index = 0; index < eligible.length; index++)
          eligible[random.nextInt(eligible.length)],
      ];
      var bestIndex = -1;
      var bestEffect = -1.0;
      for (var index = 0; index < candidates.length; index++) {
        final candidate = candidates[index];
        final split = _split(resampled, candidate.boundary);
        if (split.$1.length < minimumPerPhase ||
            split.$2.length < minimumPerPhase) {
          continue;
        }
        final systolic = _shrunkenMean(split.$1, priorMean, priorVariance);
        final diastolic = _shrunkenMean(split.$2, priorMean, priorVariance);
        final effect = log(max(1.0, systolic) / max(1.0, diastolic)).abs();
        if (effect > bestEffect) {
          bestEffect = effect;
          bestIndex = index;
        }
      }
      if (bestIndex >= 0) {
        wins[bestIndex]++;
        validDraws++;
      }
    }
    if (validDraws == 0) return null;
    var bestIndex = 0;
    for (var index = 1; index < wins.length; index++) {
      if (wins[index] > wins[bestIndex]) bestIndex = index;
    }
    final best = candidates[bestIndex];

    final winningBoundaries = <double>[];
    for (var index = 0; index < candidates.length; index++) {
      winningBoundaries.addAll(
        List<double>.filled(wins[index], candidates[index].boundary),
      );
    }
    winningBoundaries.sort();
    final boundaryLower = _quantile(winningBoundaries, 0.025);
    final boundaryUpper = _quantile(winningBoundaries, 0.975);
    final nearWins = [
      for (var index = 0; index < candidates.length; index++)
        if ((candidates[index].boundary - best.boundary).abs() <=
            config.adaptiveStepPercent)
          wins[index],
    ].fold<int>(0, (sum, value) => sum + value);

    final ratioSamples = <double>[];
    for (var draw = 0; draw < draws; draw++) {
      final resampled = [
        for (var index = 0; index < eligible.length; index++)
          eligible[random.nextInt(eligible.length)],
      ];
      final split = _split(resampled, best.boundary);
      if (split.$1.length < minimumPerPhase ||
          split.$2.length < minimumPerPhase) {
        continue;
      }
      ratioSamples.add(
        _shrunkenMean(split.$1, priorMean, priorVariance) /
            _shrunkenMean(split.$2, priorMean, priorVariance),
      );
    }
    if (ratioSamples.isEmpty) return null;
    ratioSamples.sort();
    final ratioLower = _quantile(ratioSamples, 0.025);
    final ratioUpper = _quantile(ratioSamples, 0.975);
    final systolicMean = _mean(best.systolic)!;
    final diastolicMean = _mean(best.diastolic)!;
    final ratio = systolicMean / diastolicMean;
    final probabilityBest = wins[bestIndex] / validDraws;
    final probabilityNearBest = nearWins / validDraws;
    final meaningfulEffect = log(ratio).abs() >= log(1.05);
    final excludesNoEffect = ratioLower > 1 || ratioUpper < 1;
    final stable =
        probabilityNearBest >= 0.7 &&
        boundaryUpper - boundaryLower <=
            max(15.0, config.adaptiveStepPercent * 3);
    final established = meaningfulEffect && excludesNoEffect && stable;
    final status = established
        ? 'Established functional boundary'
        : [
            if (!meaningfulEffect) 'RT effect below 5%',
            if (!excludesNoEffect) '95% ratio interval includes 1.0',
            if (!stable) 'boundary unstable across bootstrap samples',
          ].join('; ');
    return HeartSyncBoundarySummary(
      boundaryPercent: best.boundary,
      boundaryLowerPercent: boundaryLower,
      boundaryUpperPercent: boundaryUpper,
      effectMagnitude: log(ratio).abs(),
      probabilityBest: probabilityBest,
      probabilityNearBest: probabilityNearBest,
      ratioLower: ratioLower,
      ratioUpper: ratioUpper,
      isEstablished: established,
      status: status,
      metrics: HeartSyncRtSummary(
        systolicMeanMs: systolicMean,
        diastolicMeanMs: diastolicMean,
        ratio: ratio,
        systolicCount: best.systolic.length,
        diastolicCount: best.diastolic.length,
      ),
      eligibleTrials: eligible.length,
      candidatesEvaluated: candidates.length,
    );
  }

  static (List<double>, List<double>) _split(
    List<HeartSyncTrialResult> trials,
    double boundary,
  ) {
    final systolic = <double>[];
    final diastolic = <double>[];
    for (final trial in trials) {
      final percent = trial.postHocPhasePercent!;
      final target = percent <= boundary || percent >= 100 - boundary
          ? systolic
          : diastolic;
      target.add(trial.reactionTimeMs!);
    }
    return (systolic, diastolic);
  }

  static double _shrunkenMean(
    List<double> values,
    double priorMean,
    double priorVariance,
  ) {
    final mean = _mean(values)!;
    final variance = max(_variance(values, mean), 400.0);
    final priorPrecision = 1 / priorVariance;
    final dataPrecision = values.length / variance;
    final posteriorVariance = 1 / (priorPrecision + dataPrecision);
    return posteriorVariance *
        (priorMean * priorPrecision + mean * dataPrecision);
  }

  static double? _mean(List<double> values) => values.isEmpty
      ? null
      : values.reduce((left, right) => left + right) / values.length;

  static double _variance(List<double> values, double mean) {
    if (values.length < 2) return 40000;
    return values.fold<double>(0, (sum, value) => sum + pow(value - mean, 2)) /
        (values.length - 1);
  }

  static double _quantile(List<double> sorted, double probability) {
    if (sorted.length == 1) return sorted.first;
    final position = probability * (sorted.length - 1);
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    final fraction = position - lower;
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction;
  }
}

class _BoundaryCandidate {
  const _BoundaryCandidate({
    required this.boundary,
    required this.systolic,
    required this.diastolic,
  });

  final double boundary;
  final List<double> systolic;
  final List<double> diastolic;
}
