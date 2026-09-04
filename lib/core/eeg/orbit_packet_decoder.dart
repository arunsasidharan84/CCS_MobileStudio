import 'dart:convert';
import 'dart:math';

import 'ads1299_scaling.dart';

/// Stateful decoder for the ORBIT JSON stream used by NeuroYukti.
///
/// A/B are ADS1299 counts and are converted to microvolts. E is the optical
/// PPG sample; firmware may send one E value for a four-sample A/B packet, so
/// the value is held across all EEG samples in that packet.
class OrbitPacketDecoder {
  static const double eegMicrovoltsPerCount =
      Ads1299Scaling.orbitMicrovoltsPerCount;

  double _ppgX1 = 0;
  double _ppgY1 = 0;
  double _ppgSmooth = 0;
  double _previousDisplayPpg = 0;
  bool _hasPreviousDisplayPpg = false;
  bool _ppgInitialized = false;

  void reset() {
    _ppgX1 = 0;
    _ppgY1 = 0;
    _ppgSmooth = 0;
    _previousDisplayPpg = 0;
    _hasPreviousDisplayPpg = false;
    _ppgInitialized = false;
  }

  List<List<double>> decode(String packet) {
    return decodeDetailed(packet).displaySamples;
  }

  OrbitDecodedPacket decodeDetailed(String packet) {
    final normalized = packet.replaceAllMapped(
      RegExp(r'([\{,]\s*)([A-Za-z]+)(\s*:)'),
      (match) => '${match.group(1)}"${match.group(2)}"${match.group(3)}',
    );
    final json = jsonDecode(normalized) as Map<String, dynamic>;
    final a = _numberList(json['A']);
    final b = _numberList(json['B']);
    final ppg = _numberList(json['E']);
    final count = min(a.length, b.length);
    final filteredPpg = ppg.map(filterPpg).toList(growable: false);
    final samples = <List<double>>[];

    final ppgTarget = filteredPpg.isEmpty ? 0.0 : filteredPpg.last;
    final ppgStart = _hasPreviousDisplayPpg ? _previousDisplayPpg : ppgTarget;
    for (var index = 0; index < count; index++) {
      // Orbit normally supplies one optical sample per four EEG samples.
      // Interpolate causally from the previous native PPG value to this one
      // to produce a smooth 250 Hz representation for display/combined EDF.
      final fraction = count == 0 ? 1.0 : (index + 1) / count;
      final displayPpg = filteredPpg.isEmpty
          ? 0.0
          : ppgStart + (ppgTarget - ppgStart) * fraction;
      samples.add([
        eegMicrovoltsPerCount * a[index],
        eegMicrovoltsPerCount * b[index],
        displayPpg,
      ]);
    }
    if (filteredPpg.isNotEmpty) {
      _previousDisplayPpg = ppgTarget;
      _hasPreviousDisplayPpg = true;
    }
    return OrbitDecodedPacket(displaySamples: samples, ppgSamples: filteredPpg);
  }

  double filterPpg(double rawPpg, {double sampleRate = 62.5}) {
    // Establish the optical DC level before applying the high-pass recursion.
    // Starting x[n-1] at zero turns the sensor's large DC component into a
    // long artificial ramp in the viewer.
    if (!_ppgInitialized) {
      _ppgX1 = rawPpg;
      _ppgY1 = 0;
      _ppgSmooth = 0;
      _ppgInitialized = true;
      return 0;
    }
    // Orbit's JSON packets contain one PPG value for four 250 Hz EEG samples,
    // so this filter normally runs at 62.5 Hz. Fixed coefficients previously
    // treated it as a 250 Hz stream, leaving a multi-second contact transient
    // and over-smoothing the pulse. Keep the response consistent for either
    // protocol by deriving both poles from the actual input rate.
    final safeRate = sampleRate.clamp(1.0, 2000.0);
    final dcPole = exp(-2 * pi * 0.5 / safeRate);
    final smoothingAlpha = 1 - exp(-2 * pi * 5.0 / safeRate);
    final dcBlocked = rawPpg - _ppgX1 + dcPole * _ppgY1;
    _ppgX1 = rawPpg;
    _ppgY1 = dcBlocked;
    _ppgSmooth = smoothingAlpha * dcBlocked + (1 - smoothingAlpha) * _ppgSmooth;
    return _ppgSmooth * 0.15;
  }

  static List<double> _numberList(Object? value) {
    if (value is List) {
      return value.whereType<num>().map((entry) => entry.toDouble()).toList();
    }
    if (value is num) return [value.toDouble()];
    return const [];
  }
}

class OrbitDecodedPacket {
  const OrbitDecodedPacket({
    required this.displaySamples,
    required this.ppgSamples,
  });

  final List<List<double>> displaySamples;
  final List<double> ppgSamples;
}

/// Gentle DC blocker used when writing ADS1299 electrophysiology to EDF.
///
/// The first value establishes the electrode baseline, avoiding a large
/// start-up transient. At 250 Hz, r=0.995 is approximately a 0.2 Hz high-pass.
class OrbitEegDcBlocker {
  double _previousInput = 0;
  double _previousOutput = 0;
  bool _initialized = false;

  double process(double input) {
    if (!_initialized) {
      _previousInput = input;
      _initialized = true;
      return 0;
    }
    final output = input - _previousInput + 0.995 * _previousOutput;
    _previousInput = input;
    _previousOutput = output;
    return output;
  }

  void reset() {
    _previousInput = 0;
    _previousOutput = 0;
    _initialized = false;
  }
}
