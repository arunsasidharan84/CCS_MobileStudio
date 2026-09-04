import 'dart:math' as math;

import '../models/device_profile.dart';

enum BiosignalType { eeg, eog, emg, ecg, ppg, other }

BiosignalType biosignalTypeForLabel(String label) {
  final normalized = label.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (normalized.contains('EOG') ||
      normalized.startsWith('LOC') ||
      normalized.startsWith('ROC')) {
    return BiosignalType.eog;
  }
  if (normalized.contains('EMG') ||
      normalized.contains('CHIN') ||
      normalized.contains('MENTAL')) {
    return BiosignalType.emg;
  }
  if (normalized.contains('ECG') || normalized.contains('EKG')) {
    return BiosignalType.ecg;
  }
  if (normalized.contains('PPG') || normalized.contains('PLETH')) {
    return BiosignalType.ppg;
  }
  return BiosignalType.eeg;
}

BiosignalType biosignalTypeForSignalType(SignalType type) => switch (type) {
  SignalType.eeg => BiosignalType.eeg,
  SignalType.eog => BiosignalType.eog,
  SignalType.emg => BiosignalType.emg,
  SignalType.ecg => BiosignalType.ecg,
  SignalType.ppg => BiosignalType.ppg,
  SignalType.fnirs ||
  SignalType.marker ||
  SignalType.auxiliary => BiosignalType.other,
};

class DisplayFilterSettings {
  const DisplayFilterSettings({
    this.eegHighPassHz = 0.3,
    this.eegLowPassHz = 35.0,
    this.eogHighPassHz = 0.3,
    this.eogLowPassHz = 15.0,
    this.emgHighPassHz = 10.0,
    this.emgLowPassHz = 100.0,
    this.ecgHighPassHz = 0.5,
    this.ecgLowPassHz = 40.0,
    this.notchFrequencyHz = 50.0,
  });

  final double eegHighPassHz;
  final double eegLowPassHz;
  final double eogHighPassHz;
  final double eogLowPassHz;
  final double emgHighPassHz;
  final double emgLowPassHz;
  final double ecgHighPassHz;
  final double ecgLowPassHz;
  final double notchFrequencyHz;

  (double, double)? bandFor(BiosignalType type) => switch (type) {
    BiosignalType.eeg => (eegHighPassHz, eegLowPassHz),
    BiosignalType.eog => (eogHighPassHz, eogLowPassHz),
    BiosignalType.emg => (emgHighPassHz, emgLowPassHz),
    BiosignalType.ecg => (ecgHighPassHz, ecgLowPassHz),
    BiosignalType.ppg || BiosignalType.other => null,
  };
}

/// Applies channel-reference derivations without changing the recorded signal.
class DisplayMontage {
  static List<double> apply(
    List<double> channels,
    List<String> labels,
    Map<String, String> references,
  ) {
    final labelIndices = <String, int>{
      for (var i = 0; i < labels.length; i++) labels[i]: i,
    };
    return List<double>.generate(channels.length, (index) {
      if (index >= labels.length) return channels[index];
      final referenceLabel = references[labels[index]];
      final referenceIndex = referenceLabel == null
          ? null
          : labelIndices[referenceLabel];
      if (referenceIndex == null ||
          referenceIndex == index ||
          referenceIndex >= channels.length) {
        return channels[index];
      }
      return channels[index] - channels[referenceIndex];
    }, growable: false);
  }

  static List<String> labels(
    List<String> channelLabels,
    Map<String, String> references,
  ) => List<String>.generate(channelLabels.length, (index) {
    final label = channelLabels[index];
    final reference = references[label];
    return reference == null || reference == label
        ? label
        : '$label-$reference';
  }, growable: false);
}

class BiquadFilter {
  BiquadFilter({
    required double b0,
    required double b1,
    required double b2,
    required double a1,
    required double a2,
  }) : _b0 = b0,
       _b1 = b1,
       _b2 = b2,
       _a1 = a1,
       _a2 = a2;

  factory BiquadFilter.lowPass(double sampleRate, double cutoffHz) {
    return _design(sampleRate, cutoffHz, _BiquadKind.lowPass);
  }

  factory BiquadFilter.highPass(double sampleRate, double cutoffHz) {
    return _design(sampleRate, cutoffHz, _BiquadKind.highPass);
  }

  factory BiquadFilter.notch(double sampleRate, double frequencyHz) {
    return _design(sampleRate, frequencyHz, _BiquadKind.notch);
  }

  static BiquadFilter _design(
    double sampleRate,
    double frequencyHz,
    _BiquadKind kind,
  ) {
    final nyquist = sampleRate * 0.5;
    final frequency = frequencyHz.clamp(0.01, nyquist * 0.95);
    final omega = 2 * math.pi * frequency / sampleRate;
    final cosine = math.cos(omega);
    final sine = math.sin(omega);
    final quality = kind == _BiquadKind.notch
        ? 30.0
        : math.sqrt(0.5); // Butterworth Q.
    final alpha = sine / (2 * quality);
    late double b0;
    late double b1;
    late double b2;
    switch (kind) {
      case _BiquadKind.lowPass:
        b0 = (1 - cosine) * 0.5;
        b1 = 1 - cosine;
        b2 = b0;
      case _BiquadKind.highPass:
        b0 = (1 + cosine) * 0.5;
        b1 = -(1 + cosine);
        b2 = b0;
      case _BiquadKind.notch:
        b0 = 1;
        b1 = -2 * cosine;
        b2 = 1;
    }
    final a0 = 1 + alpha;
    return BiquadFilter(
      b0: b0 / a0,
      b1: b1 / a0,
      b2: b2 / a0,
      a1: (-2 * cosine) / a0,
      a2: (1 - alpha) / a0,
    );
  }

  final double _b0, _b1, _b2, _a1, _a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double process(double x) {
    final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  /// Initializes the delay elements to the steady-state response for a
  /// constant input. This prevents a large artificial transient when a live
  /// stream or a newly enabled filter starts with a non-zero electrode offset.
  void prime(double constantInput) {
    _x1 = _x2 = constantInput;
    final denominator = 1 + _a1 + _a2;
    final steadyOutput = denominator.abs() < 1e-12
        ? 0.0
        : ((_b0 + _b1 + _b2) * constantInput) / denominator;
    _y1 = _y2 = steadyOutput;
  }

  void reset() => _x1 = _x2 = _y1 = _y2 = 0;
}

enum _BiquadKind { lowPass, highPass, notch }

class _ChannelFilterCascade {
  _ChannelFilterCascade({
    required double sampleRate,
    required double highPassHz,
    required double lowPassHz,
    required double notchFrequencyHz,
  }) : highPass = BiquadFilter.highPass(sampleRate, highPassHz),
       lowPass = BiquadFilter.lowPass(
         sampleRate,
         math.min(lowPassHz, sampleRate * 0.45),
       ),
       notch = notchFrequencyHz < sampleRate * 0.48
           ? BiquadFilter.notch(sampleRate, notchFrequencyHz)
           : null;

  final BiquadFilter highPass;
  final BiquadFilter lowPass;
  final BiquadFilter? notch;
  bool _initialized = false;

  double process(
    double value, {
    required bool useNotch,
    required bool useBand,
  }) {
    if (!_initialized) {
      // Prime every active stage from the actual first sample. A zero-state
      // high-pass/notch interprets the electrode DC offset as a large signal
      // edge and can take several seconds to settle.
      if (useNotch) notch?.prime(value);
      if (useBand) {
        highPass.prime(value);
        lowPass.prime(0);
      }
      _initialized = true;
    }
    var output = value;
    if (useNotch) output = notch?.process(output) ?? output;
    if (useBand) {
      output = highPass.process(output);
      output = lowPass.process(output);
    }
    return output;
  }
}

/// Per-channel, sample-rate-aware display filtering. Raw recording is untouched.
class DisplayFilter {
  final List<_ChannelFilterCascade?> _cascades = [];
  final List<String?> _configurationKeys = [];

  List<double> process(
    List<double> channels, {
    List<String> labels = const [],
    List<SignalType> channelTypes = const [],
    double sampleRate = 250.0,
    bool notch = true,
    bool bandpass = true,
    DisplayFilterSettings settings = const DisplayFilterSettings(),
  }) {
    while (_cascades.length < channels.length) {
      _cascades.add(null);
      _configurationKeys.add(null);
    }
    return List<double>.generate(channels.length, (index) {
      final label = index < labels.length ? labels[index] : 'EEG';
      final type = index < channelTypes.length
          ? biosignalTypeForSignalType(channelTypes[index])
          : biosignalTypeForLabel(label);
      final band = settings.bandFor(type);
      if (band == null) return channels[index];
      final key =
          '${sampleRate.toStringAsFixed(4)}:$type:${band.$1}:${band.$2}:${settings.notchFrequencyHz}';
      if (_configurationKeys[index] != key) {
        _configurationKeys[index] = key;
        _cascades[index] = _ChannelFilterCascade(
          sampleRate: sampleRate,
          highPassHz: band.$1,
          lowPassHz: band.$2,
          notchFrequencyHz: settings.notchFrequencyHz,
        );
      }
      return _cascades[index]!.process(
        channels[index],
        useNotch: notch,
        useBand: bandpass,
      );
    }, growable: false);
  }

  void reset() {
    for (var i = 0; i < _cascades.length; i++) {
      _cascades[i] = null;
      _configurationKeys[i] = null;
    }
  }
}
