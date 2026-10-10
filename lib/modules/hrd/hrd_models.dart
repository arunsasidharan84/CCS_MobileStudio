import 'dart:math';

enum HrdEcgMethod { neurokit, scipyFallback }

enum HrdResponseMode { buttons, combinedSlider }

class HrdConfig {
  const HrdConfig({
    this.trials = 10,
    this.catchTrials = 2,
    this.epochSeconds = 16,
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
  final int trials, catchTrials, epochSeconds;
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
        channel.trim().isEmpty) {
      throw ArgumentError(
        'Use 1–1000 trials, 0–trial count catches, 4–120 seconds, and a channel label.',
      );
    }
  }

  Map<String, Object> toJson() => {
    'trials': trials,
    'catchTrials': catchTrials,
    'epochSeconds': epochSeconds,
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
