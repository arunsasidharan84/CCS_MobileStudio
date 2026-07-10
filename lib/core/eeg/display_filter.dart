import 'dart:math' as math;

/// Second-order IIR biquad filter section.
class BiquadFilter {
  BiquadFilter({
    required double b0,
    required double b1,
    required double b2,
    required double a1,
    required double a2,
  })  : _b0 = b0,
        _b1 = b1,
        _b2 = b2,
        _a1 = a1,
        _a2 = a2;

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

  void reset() {
    _x1 = _x2 = _y1 = _y2 = 0;
  }
}

/// Cascade of biquad filters applied to a single EEG channel.
///
/// Pre-computed for **250 Hz** sample rate.
class ChannelFilterCascade {
  ChannelFilterCascade()
      : _notch = BiquadFilter(
          b0: 0.9546059,
          b1: -0.5899788,
          b2: 0.9546059,
          a1: -0.5899788,
          a2: 0.9092117,
        ),
        _hp = BiquadFilter(
          b0: 0.982385,
          b1: -1.96477,
          b2: 0.982385,
          a1: -1.964462,
          a2: 0.96508,
        ),
        _lp = BiquadFilter(
          b0: 0.091315,
          b1: 0.18263,
          b2: 0.091315,
          a1: -0.982406,
          a2: 0.347665,
        );

  final BiquadFilter _notch;
  final BiquadFilter _hp;
  final BiquadFilter _lp;

  double process(double x, {bool notch = true, bool bandpass = true}) {
    double y = x;
    if (notch) y = _notch.process(y);
    if (bandpass) {
      y = _hp.process(y);
      y = _lp.process(y);
    }
    return y;
  }

  void reset() {
    _notch.reset();
    _hp.reset();
    _lp.reset();
  }
}

/// Manages per-channel filter cascades for the EEG display.
///
/// Applied **only for display** — raw data is written to EDF.
class DisplayFilter {
  final List<ChannelFilterCascade> _cascades = [];

  void ensureChannels(int count) {
    while (_cascades.length < count) {
      _cascades.add(ChannelFilterCascade());
    }
  }

  /// Apply filters to a multi-channel sample and return the filtered values.
  List<double> process(
    List<double> channels, {
    bool notch = true,
    bool bandpass = true,
  }) {
    ensureChannels(channels.length);
    return List.generate(
      channels.length,
      (i) => _cascades[i].process(
        channels[i],
        notch: notch,
        bandpass: bandpass,
      ),
    );
  }

  void reset() {
    for (final c in _cascades) {
      c.reset();
    }
  }
}
