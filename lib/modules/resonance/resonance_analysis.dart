import 'dart:math';
import 'resonance_config.dart';

class ResonanceInterval {
  const ResonanceInterval(this.seconds, this.ms, {this.accepted = true});
  final double seconds;
  final double ms;
  final bool accepted;
  Map<String, Object> toJson() => {
    'seconds': seconds,
    'intervalMs': ms,
    'accepted': accepted,
  };
}

class ResonanceMetrics {
  const ResonanceMetrics({
    required this.rate,
    required this.amplitudeMs,
    required this.fitR2,
    required this.sdnnMs,
    required this.rmssdMs,
    required this.coverage,
    required this.acceptedFraction,
    required this.logNoise,
    required this.reason,
  });
  final double rate,
      amplitudeMs,
      fitR2,
      sdnnMs,
      rmssdMs,
      coverage,
      acceptedFraction,
      logNoise;
  final String? reason;
  bool get valid => reason == null;
  Map<String, Object?> toJson() => {
    'rate': rate,
    'amplitudeMs': amplitudeMs,
    'fitR2': fitR2,
    'sdnnMs': sdnnMs,
    'rmssdMs': rmssdMs,
    'coverage': coverage,
    'acceptedFraction': acceptedFraction,
    'logNoise': logNoise,
    'valid': valid,
    'reason': reason,
  };
}

/// Fits offset + linear trend + sin/cos directly to irregular interval times.
/// No interpolation across rejected intervals, and no LF/HF autonomic claims.
ResonanceMetrics analyzeResonance(
  List<ResonanceInterval> intervals,
  double rate,
  double duration, {
  ResonanceConfig config = const ResonanceConfig(),
}) {
  final good = intervals
      .where(
        (x) =>
            x.accepted &&
            x.ms.isFinite &&
            x.seconds.isFinite &&
            x.ms >= 300 &&
            x.ms <= 2000,
      )
      .toList();
  final fraction = intervals.isEmpty ? 0.0 : good.length / intervals.length;
  final coverage = duration <= 0
      ? 0.0
      : (good.fold<double>(0, (sum, x) => sum + x.ms / 1000) / duration).clamp(
          0.0,
          1.0,
        );
  double amplitude = 0, r2 = 0, sdnn = 0, rmssd = 0, noise = 1;
  if (good.length >= 8 && duration > 0) {
    final mean = good.fold<double>(0, (sum, x) => sum + x.ms) / good.length;
    final matrix = List.generate(4, (_) => List.filled(5, 0.0));
    List<double> row(ResonanceInterval x) => [
      1,
      (x.seconds - duration / 2) / duration,
      sin(2 * pi * rate / 60 * x.seconds),
      cos(2 * pi * rate / 60 * x.seconds),
    ];
    for (final x in good) {
      final v = row(x);
      for (var i = 0; i < 4; i++) {
        for (var j = 0; j < 4; j++) {
          matrix[i][j] += v[i] * v[j];
        }
        matrix[i][4] += v[i] * x.ms;
      }
    }
    final beta = _solve(matrix);
    if (beta != null) {
      amplitude = sqrt(beta[2] * beta[2] + beta[3] * beta[3]);
      double sse = 0, trendSse = 0, variance = 0, differences = 0;
      var adjacent = 0;
      // Fit an independent linear trend as the null model for partial R².
      double sx = 0, sy = 0, sxx = 0, sxy = 0;
      for (final x in good) {
        final t = row(x)[1];
        sx += t;
        sy += x.ms;
        sxx += t * t;
        sxy += t * x.ms;
      }
      final denom = good.length * sxx - sx * sx;
      final slope = denom.abs() < 1e-9
          ? 0.0
          : (good.length * sxy - sx * sy) / denom;
      final offset = (sy - slope * sx) / good.length;
      for (var i = 0; i < good.length; i++) {
        final x = good[i], v = row(good[i]);
        final predicted = List.generate(
          4,
          (j) => v[j] * beta[j],
        ).reduce((a, b) => a + b);
        sse += pow(x.ms - predicted, 2).toDouble();
        trendSse += pow(x.ms - offset - slope * v[1], 2).toDouble();
        variance += pow(x.ms - mean, 2).toDouble();
        // Only adjacent original intervals contribute to RMSSD.
      }
      for (var i = 1; i < intervals.length; i++) {
        if (intervals[i].accepted && intervals[i - 1].accepted) {
          differences += pow(
            intervals[i].ms - intervals[i - 1].ms,
            2,
          ).toDouble();
          adjacent++;
        }
      }
      r2 = trendSse <= 1e-9 ? 0 : (1 - sse / trendSse).clamp(0.0, 1.0);
      sdnn = sqrt(variance / (good.length - 1));
      rmssd = adjacent == 0 ? 0 : sqrt(differences / adjacent);
      // Conservative epoch uncertainty floor: beats are serially correlated.
      noise = max(
        config.noiseFloor,
        sqrt(sse / max(1, good.length - 4)) /
            max(config.minAmplitudeMs, amplitude) /
            sqrt(max(1, duration * rate / 60)),
      );
    }
  }
  final reason = duration < 90 || duration * rate / 60 < config.minCycles
      ? 'Too few breathing cycles'
      : good.length < config.minIntervals
      ? 'Too few clean intervals'
      : fraction < config.minAccepted
      ? 'Too many intervals rejected'
      : coverage < config.minCoverage
      ? 'Insufficient signal coverage'
      : amplitude < config.minAmplitudeMs || r2 < config.minFitR2
      ? 'Weak or irregular paced response'
      : null;
  return ResonanceMetrics(
    rate: rate,
    amplitudeMs: amplitude,
    fitR2: r2,
    sdnnMs: sdnn,
    rmssdMs: rmssd,
    coverage: coverage,
    acceptedFraction: fraction,
    logNoise: noise,
    reason: reason,
  );
}

List<double>? _solve(List<List<double>> a) {
  for (var i = 0; i < 4; i++) {
    var pivot = i;
    for (var k = i + 1; k < 4; k++) {
      if (a[k][i].abs() > a[pivot][i].abs()) pivot = k;
    }
    final temp = a[i];
    a[i] = a[pivot];
    a[pivot] = temp;
    if (a[i][i].abs() < 1e-9) return null;
    final scale = a[i][i];
    for (var j = i; j <= 4; j++) {
      a[i][j] /= scale;
    }
    for (var k = 0; k < 4; k++) {
      if (k == i) continue;
      final factor = a[k][i];
      for (var j = i; j <= 4; j++) {
        a[k][j] -= factor * a[i][j];
      }
    }
  }
  return List.generate(4, (i) => a[i][4]);
}

/// Psi-inspired continuous-outcome design. Marginalize peak height and width
/// and minimize expected entropy of the optimum rate. This is experimental,
/// not the HRD psychometric likelihood applied to physiological measurements.
class ResonancePosterior {
  final ResonanceConfig config;
  late final List<double> rates;
  final _models = <({int peak, double height, double width})>[];
  late List<double> weights;
  int observations = 0;
  ResonancePosterior({this.config = const ResonanceConfig()}) {
    config.validate();
    rates = rateGrid(config.minRate, config.maxRate, config.adaptiveStep);
    for (var i = 0; i < rates.length; i++) {
      for (final height in [10.0, 20.0, 40.0, 80.0, 160.0, 320.0]) {
        for (final width in [0.4, 0.8, 1.5, 3.0]) {
          _models.add((peak: i, height: log(height), width: width));
        }
      }
    }
    weights = List.filled(_models.length, 1 / _models.length);
  }
  double _predict(int i, double rate) =>
      _models[i].height -
      pow((rate - rates[_models[i].peak]) / _models[i].width, 2) / 2;
  List<double> get marginal => _marginal(weights);
  List<double> _marginal(List<double> w) {
    final p = List.filled(rates.length, 0.0);
    for (var i = 0; i < w.length; i++) {
      p[_models[i].peak] += w[i];
    }
    return p;
  }

  double get bestRate {
    final p = marginal;
    return rates[p.indexOf(p.reduce(max))];
  }

  (double, double) get interval95 {
    final p = marginal;
    double sum = 0, lo = rates.first, hi = rates.last;
    var lowerFound = false;
    for (var i = 0; i < p.length; i++) {
      sum += p[i];
      if (!lowerFound && sum >= 0.025) {
        lo = rates[i];
        lowerFound = true;
      }
      if (sum >= 0.975) {
        hi = rates[i];
        break;
      }
    }
    return (lo, hi);
  }

  void update(ResonanceMetrics m) {
    if (!m.valid) return;
    final y = log(m.amplitudeMs), sigma = max(config.noiseFloor, m.logNoise);
    final logs = List.generate(
      weights.length,
      (i) =>
          log(max(weights[i], 1e-300)) -
          pow((y - _predict(i, m.rate)) / sigma, 2) / 2,
    );
    final largest = logs.reduce(max);
    weights = logs.map((x) => exp(x - largest)).toList();
    final total = weights.reduce((a, b) => a + b);
    weights = weights.map((x) => x / total).toList();
    observations++;
  }

  double nextRate() {
    // Seed broad coverage before making model-dependent choices.
    if (observations < 3) {
      final target =
          (config.minRate + config.maxRate) / 2 +
          min(0.5, (config.maxRate - config.minRate) / 4);
      final seed = rates.reduce(
        (a, b) => (a - target).abs() <= (b - target).abs() ? a : b,
      );
      return [seed, rates.first, rates.last][observations];
    }
    var best = rates[rates.length ~/ 2], least = double.infinity;
    for (final rate in rates) {
      // Discretized Gaussian posterior-predictive quadrature, including tails.
      final means = List.generate(_models.length, (i) => _predict(i, rate));
      final lower = means.reduce(min) - 3 * config.planningNoise;
      final upper = means.reduce(max) + 3 * config.planningNoise;
      final binStep = (upper - lower) / 80;
      final probabilities = List.generate(_models.length, (i) {
        final mean = _predict(i, rate);
        final logBins = List.generate(
          81,
          (j) =>
              -pow((lower + j * binStep - mean) / config.planningNoise, 2) / 2,
        );
        final largest = logBins.reduce(max);
        final bins = logBins.map((x) => exp(x - largest)).toList();
        final total = bins.reduce((a, b) => a + b);
        return bins.map((p) => p / total).toList();
      });
      double expected = 0;
      for (var j = 0; j < 81; j++) {
        final w = List.generate(
          weights.length,
          (i) => weights[i] * probabilities[i][j],
        );
        final mass = w.reduce((a, b) => a + b);
        if (mass < 1e-12) continue;
        final marginal = _marginal(w);
        for (final p in marginal) {
          if (p > 0) expected -= p * log(p / mass);
        }
      }
      if (expected < least) {
        least = expected;
        best = rate;
      }
    }
    return best;
  }
}
