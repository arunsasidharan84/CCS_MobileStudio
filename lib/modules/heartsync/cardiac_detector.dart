import 'dart:collection';
import 'dart:math';

import 'models.dart';

/// Low-allocation causal detector for real-time PPG pulses or ECG R-waves.
/// Post-task assignment deliberately uses a separate, zero-phase-style pass.
class CardiacDetector {
  CardiacDetector(this.config);

  final HeartSyncConfig config;
  final Queue<double> _window = Queue<double>();
  final Queue<double> _ipiMs = Queue<double>();
  DateTime? _lastPeak;
  DateTime? _previousTimestamp;
  double? _previousFiltered;
  double? _previousRaw;
  double _highPassed = 0;
  double _filtered = 0;
  bool _armed = true;

  double get meanIpiMs {
    if (_ipiMs.isEmpty) return 900;
    final sorted = _ipiMs.toList()..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }

  DateTime? add(CardiacSample sample) {
    final raw = config.pulseMode == HeartSyncPulseMode.ppg
        ? sample.value
        : sample.value.abs();
    final previousRaw = _previousRaw;
    final previousTimestamp = _previousTimestamp;
    final previousFiltered = _previousFiltered;
    final dt = previousTimestamp == null
        ? 0.016
        : (sample.timestamp.difference(previousTimestamp).inMicroseconds /
                  1000000)
              .clamp(0.001, 0.05);
    _previousRaw = raw;
    _previousTimestamp = sample.timestamp;
    if (previousRaw == null) return null;

    final highPassRc = 1 / (2 * pi * 0.5);
    final lowPassRc = 1 / (2 * pi * 8.0);
    _highPassed =
        highPassRc / (highPassRc + dt) * (_highPassed + raw - previousRaw);
    _filtered += dt / (lowPassRc + dt) * (_highPassed - _filtered);
    _previousFiltered = _filtered;
    _window.add(_filtered);
    if (_window.length > 160) _window.removeFirst();
    if (_window.length < 80 || previousFiltered == null) return null;

    final sorted = _window.toList()..sort();
    final median = sorted[sorted.length ~/ 2];
    final p25 = sorted[(sorted.length * 0.25).floor()];
    final p75 = sorted[(sorted.length * 0.75).floor()];
    final robustSd = max((p75 - p25) / 1.349, 1e-9);
    final threshold =
        median +
        robustSd * (config.pulseMode == HeartSyncPulseMode.ecg ? 2.5 : 0.6);
    if (_filtered < median - robustSd * 0.1) _armed = true;
    final confirmedPeak = previousFiltered > _filtered;
    if (!_armed || !confirmedPeak || previousFiltered < threshold) return null;
    final peakTimestamp = previousTimestamp!;
    final last = _lastPeak;
    if (last != null &&
        peakTimestamp.difference(last).inMilliseconds < config.refractoryMs) {
      return null;
    }
    if (last != null) {
      final ipi = peakTimestamp.difference(last).inMicroseconds / 1000;
      if (ipi >= 350 && ipi <= 2000) {
        final reference = meanIpiMs;
        if (_ipiMs.length < 3 || (ipi - reference).abs() <= reference * 0.3) {
          _ipiMs.add(ipi);
        }
        while (_ipiMs.length > config.ipiHistoryLength) {
          _ipiMs.removeFirst();
        }
      }
    }
    _lastPeak = peakTimestamp;
    _armed = false;
    return peakTimestamp;
  }
}
