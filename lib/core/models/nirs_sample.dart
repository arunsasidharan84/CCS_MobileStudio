/// A single fNIRS sample from a NIRSport 2 or compatible device via LSL.
class NirsSample {
  const NirsSample({
    required this.channels,
    required this.channelNames,
    required this.sampleRate,
    required this.timestamp,
  });

  /// Raw channel values (HbO, HbR, HbT alternating, or as specified by LSL metadata)
  final List<double> channels;

  /// Channel names from LSL metadata (e.g. "S1-D1 HbO", "S1-D1 HbR")
  final List<String> channelNames;

  /// Nominal sampling rate in Hz (e.g. 10.0 for NIRSport 2)
  final double sampleRate;

  /// Wall-clock time of sample capture
  final DateTime timestamp;

  int get channelCount => channels.length;
}
