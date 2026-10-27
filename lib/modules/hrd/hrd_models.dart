import 'dart:math';

enum HrdEcgMethod { neurokit, scipyFallback }

enum HrdResponseMode { buttons, combinedSlider }

class HrdConfig {
  const HrdConfig({
    this.trials = 10,
    this.catchTrials = 2,
    this.epochSeconds = 16,
    this.responseTimeoutSeconds = 8,
    this.ecg = false,
    this.channel = 'PPG',
    this.source = '',
    this.audio = true,
    this.record = true,
    this.confidence = false,
    this.simulation = false,
    this.responseMode = HrdResponseMode.buttons,
    this.ecgMethod = HrdEcgMethod.neurokit,
  });
  final int trials, catchTrials, epochSeconds, responseTimeoutSeconds;
  final bool ecg, audio, record, confidence, simulation;
  final String channel, source;
  final HrdResponseMode responseMode;
  final HrdEcgMethod ecgMethod;
  void validate() {
    if (trials < 1 ||
        trials > 1000 ||
        catchTrials < 0 ||
        catchTrials > trials ||
        epochSeconds < 4 ||
        epochSeconds > 120 ||
        responseTimeoutSeconds < 2 ||
        responseTimeoutSeconds > 120 ||
        channel.trim().isEmpty) {
      throw ArgumentError(
        'Use 1–1000 trials, 0–trial count catches, 4–120 acquisition seconds, 2–120 response timeout seconds, and a channel label.',
      );
    }
  }

  Map<String, Object> toJson() => {
    'trials': trials,
    'catchTrials': catchTrials,
    'epochSeconds': epochSeconds,
    'responseTimeoutSeconds': responseTimeoutSeconds,
    'ecg': ecg,
    'channel': channel,
    'source': source,
    'audio': audio,
    'record': record,
    'confidence': confidence,
    'simulation': simulation,
    'responseMode': responseMode.name,
    'ecgMethod': ecgMethod.name,
  };
}

List<bool> hrdCatchPlan(int trials, int catches, Random random) {
  if (trials < 1 || catches < 0 || catches > trials) {
    throw ArgumentError('Invalid trial counts');
  }
  final plan = List.filled(trials, false);
  if (catches == 0) return plan;
  plan[0] = true;
  var pool = List.generate(
    trials - max(1, trials ~/ 2),
    (i) => max(1, trials ~/ 2) + i,
  );
  if (pool.length < catches - 1) pool = List.generate(trials - 1, (i) => i + 1);
  pool.shuffle(random);
  for (final i in pool.take(catches - 1)) {
    plan[i] = true;
  }
  return plan;
}

// Python uses ties-to-even; preserve its half-BPM sound selection.
double hrdPresentedRate(double hr, double delta) {
  final scaled = (hr + delta).clamp(15.0, 199.5) * 2;
  final floor = scaled.floor();
  final rounded = scaled - floor == 0.5
      ? (floor.isEven ? floor : floor + 1)
      : scaled.round();
  return rounded / 2;
}

const hrdColumns = [
  'SubjName',
  'Trial',
  'TrialType',
  'StimType',
  'FeatureType',
  'HeartRate',
  'EstimatedRateMean',
  'EstimatedRateLow',
  'EstimatedRateHigh',
  'ActualRate',
  'PsiDeltaRate',
  'PresentedRate',
  'SubjResponse',
  'SubjRating',
  'SubjAccuracy',
  'ResponseTime',
  'PsiThreshold',
  'PsiSlope',
];

/// Neutral is deliberately not a response. Direction only updates Psi;
/// magnitude is a separate ordinal confidence measure.
class HrdSliderAnswer {
  HrdSliderAnswer(this.position) {
    if (!position.isFinite || position.abs() > 9 || position == 0) {
      throw ArgumentError('Choose a direction with confidence 1–9.');
    }
  }
  final double position;
  int get response => position > 0 ? 1 : 0;
  int get confidence => position.abs().round().clamp(1, 9);
}

/// Aggregated confidence metrics and interoceptive metacognitive calibration.
class HrdConfidenceSummary {
  const HrdConfidenceSummary({
    required this.count,
    required this.meanConfidence,
    this.correctMean,
    this.incorrectMean,
    this.metacognitiveDelta,
    this.catchMean,
    this.adaptiveMean,
    this.accuracy,
  });

  final int count;
  final double meanConfidence;
  final double? correctMean;
  final double? incorrectMean;
  final double? metacognitiveDelta;
  final double? catchMean;
  final double? adaptiveMean;
  final double? accuracy;

  Map<String, Object?> toJson() => {
    'count': count,
    'meanConfidence': meanConfidence,
    'correctMean': correctMean,
    'incorrectMean': incorrectMean,
    'metacognitiveDelta': metacognitiveDelta,
    'catchMean': catchMean,
    'adaptiveMean': adaptiveMean,
    'accuracy': accuracy,
  };

  static HrdConfidenceSummary? compute(List<Map<String, Object?>> rows) {
    final rated = rows.where((r) => r['SubjRating'] is num).toList();
    if (rated.isEmpty) return null;
    final ratings =
        rated.map((r) => (r['SubjRating'] as num).toDouble()).toList();
    final mean = ratings.reduce((a, b) => a + b) / ratings.length;
    final correct = rated
        .where((r) => r['SubjAccuracy'] == 1)
        .map((r) => (r['SubjRating'] as num).toDouble())
        .toList();
    final incorrect = rated
        .where((r) => r['SubjAccuracy'] == 0)
        .map((r) => (r['SubjRating'] as num).toDouble())
        .toList();
    final correctMean = correct.isEmpty
        ? null
        : correct.reduce((a, b) => a + b) / correct.length;
    final incorrectMean = incorrect.isEmpty
        ? null
        : incorrect.reduce((a, b) => a + b) / incorrect.length;
    final delta = (correctMean != null && incorrectMean != null)
        ? correctMean - incorrectMean
        : null;
    final catches = rated
        .where((r) => r['TrialType'] == 'catch')
        .map((r) => (r['SubjRating'] as num).toDouble())
        .toList();
    final adaptive = rated
        .where((r) => r['TrialType'] == 'psi')
        .map((r) => (r['SubjRating'] as num).toDouble())
        .toList();
    final catchMean = catches.isEmpty
        ? null
        : catches.reduce((a, b) => a + b) / catches.length;
    final adaptiveMean = adaptive.isEmpty
        ? null
        : adaptive.reduce((a, b) => a + b) / adaptive.length;
    final scored = rated.where((r) => r['SubjAccuracy'] is num).toList();
    final accuracy = scored.isEmpty
        ? null
        : scored.where((r) => r['SubjAccuracy'] == 1).length / scored.length;
    return HrdConfidenceSummary(
      count: rated.length,
      meanConfidence: mean,
      correctMean: correctMean,
      incorrectMean: incorrectMean,
      metacognitiveDelta: delta,
      catchMean: catchMean,
      adaptiveMean: adaptiveMean,
      accuracy: accuracy,
    );
  }
}

