/// A single multi-channel EEG sample.
class EegSample {
  const EegSample({
    required this.channels,
    required this.sampleRate,
    required this.timestamp,
    required this.source,
  });

  /// Channel voltages in µV.
  final List<double> channels;

  /// Nominal sample rate in Hz.
  final double sampleRate;

  /// Wall-clock timestamp of when this sample arrived.
  final DateTime timestamp;

  /// Human-readable label for the acquisition source.
  final String source;
}
