enum ResonanceMethod { conventional, adaptive }

class ResonanceConfig {
  const ResonanceConfig({
    this.method = ResonanceMethod.conventional,
    this.ecg = false,
    this.channel = 'PPG',
    this.restSeconds = 30,
    this.settleSeconds = 30,
    this.measureSeconds = 120,
    this.practiceSeconds = 300,
    this.minRate = 4.5,
    this.maxRate = 6.5,
    this.sweepStep = 0.5,
    this.adaptiveStep = 0.1,
    this.inhaleFraction = 0.5,
    this.minTrials = 5,
    this.maxTrials = 8,
    this.targetWidth = 0.4,
    this.minIntervals = 40,
    this.minCycles = 6,
    this.minAccepted = 0.9,
    this.minCoverage = 0.85,
    this.minAmplitudeMs = 5,
    this.minFitR2 = 0.25,
    this.outlierFraction = 0.35,
    this.noiseFloor = 0.25,
    this.planningNoise = 0.35,
    this.confirmRatioMin = 0.6,
    this.confirmRatioMax = 1.67,
  });
  final ResonanceMethod method;
  final bool ecg;
  final String channel;
  final int restSeconds,
      settleSeconds,
      measureSeconds,
      practiceSeconds,
      minTrials,
      maxTrials,
      minIntervals;
  final double minRate,
      maxRate,
      sweepStep,
      adaptiveStep,
      inhaleFraction,
      targetWidth,
      minCycles,
      minAccepted,
      minCoverage,
      minAmplitudeMs,
      minFitR2,
      outlierFraction,
      noiseFloor,
      planningNoise,
      confirmRatioMin,
      confirmRatioMax;
  List<double> get sweepRates =>
      rateGrid(minRate, maxRate, sweepStep).reversed.toList();
  void validate() {
    void bound(String name, num value, num lo, num hi) {
      if (!value.isFinite || value < lo || value > hi) {
        throw FormatException('$name must be between $lo and $hi.');
      }
    }

    if (channel.trim().isEmpty) {
      throw const FormatException('Enter a cardiac channel label.');
    }
    bound('Minimum pace', minRate, 4, 8);
    bound('Maximum pace', maxRate, 4, 8);
    if (maxRate - minRate < 0.5) {
      throw const FormatException(
        'Pace range must span at least 0.5 breaths/min.',
      );
    }
    bound('Sweep step', sweepStep, 0.25, 1);
    bound('Adaptive step', adaptiveStep, 0.05, 0.5);
    if (rateGrid(minRate, maxRate, adaptiveStep).length > 81) {
      throw const FormatException('Adaptive grid cannot exceed 81 rates.');
    }
    bound('Settling seconds', settleSeconds, 10, 120);
    bound('Measurement seconds', measureSeconds, 90, 300);
    bound('Rest seconds', restSeconds, 0, 300);
    bound('Practice seconds', practiceSeconds, 60, 1800);
    bound('Inhale proportion', inhaleFraction, 0.3, 0.7);
    bound('Minimum trials', minTrials, 3, 12);
    bound('Maximum trials', maxTrials, minTrials, 16);
    bound(
      'Target credible width',
      targetWidth,
      adaptiveStep,
      maxRate - minRate,
    );
    bound('Minimum clean intervals', minIntervals, 20, 200);
    bound('Minimum cycles', minCycles, 6, 20);
    if (measureSeconds * minRate / 60 < minCycles) {
      throw const FormatException(
        'Increase measurement duration to include the required cycles at the slowest pace.',
      );
    }
    bound('Accepted fraction', minAccepted, 0.7, 1);
    bound('Coverage fraction', minCoverage, 0.7, 1);
    bound('Minimum amplitude', minAmplitudeMs, 1, 100);
    bound('Minimum fit R²', minFitR2, 0.05, 0.95);
    bound('Interval outlier fraction', outlierFraction, 0.15, 0.6);
    bound('Log-response noise floor', noiseFloor, 0.1, 1);
    bound('Planning noise', planningNoise, noiseFloor, 1);
    bound('Confirmation lower ratio', confirmRatioMin, 0.1, 1);
    bound('Confirmation upper ratio', confirmRatioMax, 1, 3);
  }

  Map<String, Object> toJson() => {
    'method': method.name,
    'ecg': ecg,
    'channel': channel,
    'restSeconds': restSeconds,
    'settleSeconds': settleSeconds,
    'measureSeconds': measureSeconds,
    'practiceSeconds': practiceSeconds,
    'minRate': minRate,
    'maxRate': maxRate,
    'sweepStep': sweepStep,
    'adaptiveStep': adaptiveStep,
    'inhaleFraction': inhaleFraction,
    'minTrials': minTrials,
    'maxTrials': maxTrials,
    'targetWidth': targetWidth,
    'minIntervals': minIntervals,
    'minCycles': minCycles,
    'minAccepted': minAccepted,
    'minCoverage': minCoverage,
    'minAmplitudeMs': minAmplitudeMs,
    'minFitR2': minFitR2,
    'outlierFraction': outlierFraction,
    'noiseFloor': noiseFloor,
    'planningNoise': planningNoise,
    'confirmRatioMin': confirmRatioMin,
    'confirmRatioMax': confirmRatioMax,
  };
  factory ResonanceConfig.fromJson(Map<String, dynamic> j) {
    double d(String k, double fallback) =>
        (j[k] as num?)?.toDouble() ?? fallback;
    int i(String k, int fallback) => (j[k] as num?)?.toInt() ?? fallback;
    return ResonanceConfig(
      method: j['method'] == 'adaptive'
          ? ResonanceMethod.adaptive
          : ResonanceMethod.conventional,
      ecg: j['ecg'] == true,
      channel: j['channel'] as String? ?? 'PPG',
      restSeconds: i('restSeconds', 30),
      settleSeconds: i('settleSeconds', 30),
      measureSeconds: i('measureSeconds', 120),
      practiceSeconds: i('practiceSeconds', 300),
      minRate: d('minRate', 4.5),
      maxRate: d('maxRate', 6.5),
      sweepStep: d('sweepStep', 0.5),
      adaptiveStep: d('adaptiveStep', 0.1),
      inhaleFraction: d('inhaleFraction', 0.5),
      minTrials: i('minTrials', 5),
      maxTrials: i('maxTrials', 8),
      targetWidth: d('targetWidth', 0.4),
      minIntervals: i('minIntervals', 40),
      minCycles: d('minCycles', 6),
      minAccepted: d('minAccepted', 0.9),
      minCoverage: d('minCoverage', 0.85),
      minAmplitudeMs: d('minAmplitudeMs', 5),
      minFitR2: d('minFitR2', 0.25),
      outlierFraction: d('outlierFraction', 0.35),
      noiseFloor: d('noiseFloor', 0.25),
      planningNoise: d('planningNoise', 0.35),
      confirmRatioMin: d('confirmRatioMin', 0.6),
      confirmRatioMax: d('confirmRatioMax', 1.67),
    );
  }
}

List<double> rateGrid(double lo, double hi, double step) {
  // Bound allocation even for malformed persisted settings; validate before use.
  if (!lo.isFinite ||
      !hi.isFinite ||
      !step.isFinite ||
      step <= 0 ||
      hi < lo ||
      (hi - lo) / step > 100) {
    throw const FormatException('Invalid breathing-rate grid.');
  }
  final rates = List.generate(
    ((hi - lo) / step + 1e-8).floor() + 1,
    (i) => double.parse((lo + i * step).toStringAsFixed(4)),
  );
  if ((rates.last - hi).abs() > 1e-6) rates.add(hi);
  return rates;
}
