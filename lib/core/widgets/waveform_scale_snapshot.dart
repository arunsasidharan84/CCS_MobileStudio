/// Fixed display scales captured from the currently rendered autoscale values.
class WaveformScaleSnapshot {
  const WaveformScaleSnapshot({
    required this.eegUv,
    required this.ecgUv,
    required this.ppg,
  });

  factory WaveformScaleSnapshot.capture({
    required double eegUv,
    required double ecgUv,
    required double ppg,
  }) {
    return WaveformScaleSnapshot(
      eegUv: eegUv.clamp(10.0, 15000.0),
      ecgUv: ecgUv.clamp(100.0, 30000.0),
      ppg: ppg.clamp(5.0, 32768.0),
    );
  }

  final double eegUv;
  final double ecgUv;
  final double ppg;
}

class RobustWaveformAutoscale {
  const RobustWaveformAutoscale._();

  /// Estimates display amplitude from the newer half of the visible trace.
  ///
  /// Median centering and a high percentile make the scale insensitive to
  /// isolated motion/filter transients while still following sustained signal
  /// changes promptly.
  static double amplitude(
    List<double> data, {
    required int visiblePoints,
    double percentile = 0.98,
  }) {
    if (data.length < 4 || visiblePoints < 4) return 0;
    final visibleCount = visiblePoints.clamp(4, data.length);
    final secondHalfCount = (visibleCount / 2).ceil().clamp(2, data.length);
    final segment = data.sublist(data.length - secondHalfCount)..sort();
    final median = segment[segment.length ~/ 2];
    final deviations =
        segment.map((value) => (value - median).abs()).toList(growable: false)
          ..sort();
    final index = ((deviations.length - 1) * percentile).round().clamp(
      0,
      deviations.length - 1,
    );
    return deviations[index];
  }
}
