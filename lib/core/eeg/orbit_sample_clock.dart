import 'dart:math';

/// Reconstructs uniformly spaced sample timestamps from batched BLE packets.
///
/// Packet arrival time is noisy because Bluetooth and the operating system
/// deliver notifications in bursts. Using every arrival time directly makes
/// a uniform waveform appear to speed up and slow down. This small software
/// phase-locked loop advances from the previous sample clock and permits only
/// a gentle correction toward the observed arrival time.
class OrbitSampleClock {
  DateTime? _lastSample;

  DateTime firstTimestampForBatch({
    required DateTime packetArrival,
    required int sampleCount,
    required double sampleRate,
  }) {
    if (sampleRate <= 0 || sampleCount <= 0) return packetArrival;
    final periodUs = (1000000 / sampleRate).round();
    final arrivalEstimate = packetArrival.subtract(
      Duration(microseconds: periodUs * max(0, sampleCount - 1)),
    );
    final previous = _lastSample;
    DateTime first;
    if (previous == null) {
      first = arrivalEstimate;
    } else {
      final expected = previous.add(Duration(microseconds: periodUs));
      final errorUs = arrivalEstimate.difference(expected).inMicroseconds;
      // Correct by at most 1/8 sample per notification. This follows genuine
      // oscillator drift without reproducing millisecond-scale BLE jitter.
      final maxSlewUs = max(1, periodUs ~/ 8);
      final correctionUs = errorUs.clamp(-maxSlewUs, maxSlewUs);
      first = expected.add(Duration(microseconds: correctionUs));
    }
    _lastSample = first.add(
      Duration(microseconds: periodUs * max(0, sampleCount - 1)),
    );
    return first;
  }

  void reset() => _lastSample = null;
}
