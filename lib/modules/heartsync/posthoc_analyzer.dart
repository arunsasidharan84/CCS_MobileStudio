import 'dart:math';

import 'adaptive_boundary_analyzer.dart';
import 'models.dart';

class HeartSyncPostHocAnalyzer {
  static HeartSyncSummary analyze(
    List<CardiacSample> samples,
    List<HeartSyncTrialResult> trials,
    HeartSyncConfig config, {
    int detectedBeats = 0,
    int collisionSkippedBeats = 0,
  }) {
    final peaks = findPeaks(samples, config);
    for (final trial in trials) {
      final previousIndex = _lastPeakBefore(peaks, trial.presentedAt);
      if (previousIndex < 0 || previousIndex + 1 >= peaks.length) continue;
      final previous = peaks[previousIndex];
      final next = peaks[previousIndex + 1];
      final cycleUs = next.difference(previous).inMicroseconds;
      if (cycleUs <= 0) continue;
      final elapsedUs = trial.presentedAt.difference(previous).inMicroseconds;
      final percent = elapsedUs * 100 / cycleUs;
      if (percent < 0 || percent >= 100) continue;
      trial.postHocPhasePercent = percent;
      trial.postHocPhase =
          percent <= config.postHocSystolicEndPercent ||
              percent >= 100 - config.postHocSystolicEndPercent
          ? CardiacPhase.systole
          : CardiacPhase.diastole;
    }

    var correct = 0;
    var assigned = 0;
    for (final trial in trials) {
      if (trial.isCorrect) {
        correct++;
      }
      if (trial.postHocPhase != CardiacPhase.indeterminate) {
        assigned++;
      }
    }
    final rareCorrect = _rtSummary(
      trials,
      HeartSyncStimulusKind.rare,
      (trial) => trial.isCorrect,
    );
    return HeartSyncSummary(
      rareCorrect: rareCorrect,
      rareIncorrect: _rtSummary(
        trials,
        HeartSyncStimulusKind.rare,
        (trial) => trial.response != null && !trial.isCorrect,
      ),
      rareAllResponded: _rtSummary(
        trials,
        HeartSyncStimulusKind.rare,
        (trial) => trial.response != null,
      ),
      frequentCorrect: _rtSummary(
        trials,
        HeartSyncStimulusKind.frequent,
        (trial) => trial.isCorrect,
      ),
      frequentIncorrect: _rtSummary(
        trials,
        HeartSyncStimulusKind.frequent,
        (trial) => trial.response != null && !trial.isCorrect,
      ),
      frequentAllResponded: _rtSummary(
        trials,
        HeartSyncStimulusKind.frequent,
        (trial) => trial.response != null,
      ),
      adaptiveBoundaries: config.adaptiveOffsets
          ? {
              'rareCorrect': AdaptiveBoundaryAnalyzer.analyze(
                trials,
                config,
                HeartSyncStimulusKind.rare,
                (trial) => trial.isCorrect,
                seed: 11,
              ),
              'rareIncorrect': AdaptiveBoundaryAnalyzer.analyze(
                trials,
                config,
                HeartSyncStimulusKind.rare,
                (trial) => trial.response != null && !trial.isCorrect,
                seed: 12,
              ),
              'rareAllResponded': AdaptiveBoundaryAnalyzer.analyze(
                trials,
                config,
                HeartSyncStimulusKind.rare,
                (trial) => trial.response != null,
                seed: 13,
              ),
              'frequentCorrect': AdaptiveBoundaryAnalyzer.analyze(
                trials,
                config,
                HeartSyncStimulusKind.frequent,
                (trial) => trial.isCorrect,
                seed: 21,
              ),
              'frequentIncorrect': AdaptiveBoundaryAnalyzer.analyze(
                trials,
                config,
                HeartSyncStimulusKind.frequent,
                (trial) => trial.response != null && !trial.isCorrect,
                seed: 22,
              ),
              'frequentAllResponded': AdaptiveBoundaryAnalyzer.analyze(
                trials,
                config,
                HeartSyncStimulusKind.frequent,
                (trial) => trial.response != null,
                seed: 23,
              ),
            }
          : const {},
      correctResponses: correct,
      completedTrials: trials.length,
      postHocAssignedTrials: assigned,
      detectedBeats: detectedBeats,
      deliveryRate: detectedBeats == 0
          ? null
          : min(1.0, trials.length / detectedBeats),
      collisionSkippedBeats: collisionSkippedBeats,
    );
  }

  static HeartSyncRtSummary _rtSummary(
    List<HeartSyncTrialResult> trials,
    HeartSyncStimulusKind stimulus,
    bool Function(HeartSyncTrialResult trial) include,
  ) {
    final systolic = <double>[];
    final diastolic = <double>[];
    for (final trial in trials) {
      final rt = trial.reactionTimeMs;
      if (trial.plan.stimulus != stimulus || rt == null || !include(trial)) {
        continue;
      }
      if (trial.postHocPhase == CardiacPhase.systole) {
        systolic.add(rt);
      } else if (trial.postHocPhase == CardiacPhase.diastole) {
        diastolic.add(rt);
      }
    }
    final systolicMean = _mean(systolic);
    final diastolicMean = _mean(diastolic);
    return HeartSyncRtSummary(
      systolicMeanMs: systolicMean,
      diastolicMeanMs: diastolicMean,
      ratio: systolicMean == null || diastolicMean == null || diastolicMean == 0
          ? null
          : systolicMean / diastolicMean,
      systolicCount: systolic.length,
      diastolicCount: diastolic.length,
    );
  }

  /// Offline fiducials used for final verification plots and phase assignment.
  static List<DateTime> findPeaks(
    List<CardiacSample> samples,
    HeartSyncConfig config, {
    HeartSyncPulseMode? pulseMode,
  }) {
    if (samples.length < 5) return const [];
    final durationUs = samples.last.timestamp
        .difference(samples.first.timestamp)
        .inMicroseconds;
    final sampleRate = durationUs <= 0
        ? 250.0
        : (samples.length - 1) * 1000000 / durationUs;
    final raw = samples.map((sample) => sample.value).toList(growable: false);
    final bandpassed = _zeroPhaseBandpass(
      raw,
      sampleRate,
      config.detectionHighPassHz,
      config.detectionLowPassHz,
    );
    final mode = pulseMode ?? config.pulseMode;
    final values = mode == HeartSyncPulseMode.ecg
        ? bandpassed.map((value) => value.abs()).toList(growable: false)
        : bandpassed;
    final sorted = List<double>.of(values)..sort();
    final median = sorted[sorted.length ~/ 2];
    final p25 = sorted[(sorted.length * 0.25).floor()];
    final p75 = sorted[(sorted.length * 0.75).floor()];
    final robustSd = max((p75 - p25) / 1.349, 1e-9);
    final threshold =
        median +
        robustSd *
            (mode == HeartSyncPulseMode.ecg
                ? config.ecgThresholdSigma
                : config.ppgThresholdSigma);
    final refractorySamples = max(
      1,
      (max(600, config.refractoryMs) * sampleRate / 1000).round(),
    );
    final prominenceWindow = max(2, (sampleRate * 0.2).round());
    final peakIndices = <int>[];
    for (var i = 1; i < values.length - 1; i++) {
      if (values[i] < threshold ||
          values[i] < values[i - 1] ||
          values[i] <= values[i + 1]) {
        continue;
      }
      final leftStart = max(0, i - prominenceWindow);
      final rightEnd = min(values.length - 1, i + prominenceWindow);
      var leftMin = values[i];
      var rightMin = values[i];
      for (var j = leftStart; j < i; j++) {
        leftMin = min(leftMin, values[j]);
      }
      for (var j = i + 1; j <= rightEnd; j++) {
        rightMin = min(rightMin, values[j]);
      }
      if (values[i] - max(leftMin, rightMin) < robustSd * 0.5) continue;
      if (peakIndices.isNotEmpty && i - peakIndices.last < refractorySamples) {
        if (values[i] > values[peakIndices.last]) peakIndices.last = i;
      } else {
        peakIndices.add(i);
      }
    }
    return [for (final index in peakIndices) samples[index].timestamp];
  }

  static List<double> _zeroPhaseBandpass(
    List<double> input,
    double sampleRate,
    double highPassHz,
    double lowPassHz,
  ) {
    if (input.isEmpty || sampleRate <= 0) return List<double>.of(input);
    final forward = _onePoleBandpass(input, sampleRate, highPassHz, lowPassHz);
    return _onePoleBandpass(
      forward.reversed.toList(),
      sampleRate,
      highPassHz,
      lowPassHz,
    ).reversed.toList(growable: false);
  }

  static List<double> _onePoleBandpass(
    List<double> input,
    double sampleRate,
    double highPassHz,
    double lowPassHz,
  ) {
    final dt = 1 / sampleRate;
    final highPassRc = 1 / (2 * pi * highPassHz);
    final lowPassRc = 1 / (2 * pi * lowPassHz);
    final highAlpha = highPassRc / (highPassRc + dt);
    final lowAlpha = dt / (lowPassRc + dt);
    var previousInput = input.first;
    var previousHigh = 0.0;
    var low = 0.0;
    final output = <double>[];
    for (final value in input) {
      final high = highAlpha * (previousHigh + value - previousInput);
      low += lowAlpha * (high - low);
      output.add(low);
      previousInput = value;
      previousHigh = high;
    }
    return output;
  }

  static int _lastPeakBefore(List<DateTime> peaks, DateTime time) {
    var low = 0;
    var high = peaks.length - 1;
    var answer = -1;
    while (low <= high) {
      final middle = (low + high) ~/ 2;
      if (!peaks[middle].isAfter(time)) {
        answer = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return answer;
  }

  static double? _mean(List<double> values) =>
      values.isEmpty ? null : values.reduce((a, b) => a + b) / values.length;
}
