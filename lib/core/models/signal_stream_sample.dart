import 'device_profile.dart';

/// A sample from one independently clocked signal stream.
class SignalStreamSample {
  const SignalStreamSample({
    required this.deviceProfileId,
    required this.streamId,
    required this.signalType,
    required this.channels,
    required this.channelLabels,
    this.channelTypes = const [],
    required this.sampleRate,
    required this.timestamp,
    required this.unit,
    required this.physicalMinimum,
    required this.physicalMaximum,
  });

  final String deviceProfileId;
  final String streamId;
  final SignalType signalType;
  final List<double> channels;
  final List<String> channelLabels;
  final List<SignalType> channelTypes;
  final double sampleRate;
  final DateTime timestamp;
  final String unit;
  final double physicalMinimum;
  final double physicalMaximum;
}
