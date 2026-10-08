import 'dart:math';
import '../../core/eeg/display_filter.dart';

/// Streaming single-channel adaptation of HeartEvokedPotentials resting pipeline.
/// Input EEG and ECG are synchronized samples in microvolts.
class HepEngine {
  HepEngine(this.sampleRate, {this.notchHz = 50}) {
    if (!sampleRate.isFinite || sampleRate < 125 || sampleRate > 4000) {
      throw ArgumentError('HEP requires a sample rate of 125–4000 Hz.');
    }
    _resetFilters();
  }
  final double sampleRate, notchHz;
  late BiquadFilter hp, lp, ecgHp, ecgLp;
  BiquadFilter? notch;
  final List<double> _eeg = [], _raw = [], _ecg = [];
  final List<int> _pending = [], _controls = [];
  final List<double> _levels = [];
  late List<double> mean = List.filled(length, 0);
  late final List<double> _m2 = List.filled(length, 0);
  late List<double> pseudo = List.filled(length, 0);
  int accepted = 0, rejected = 0, beats = 0, gaps = 0, pseudoCount = 0;
  int _base = 0, _index = -1, _lastBeat = -100000;
  DateTime? _lastTime;
  double bpm = 0;
  String quality = 'Waiting for synchronized EEG + ECG';
  bool _primed = false;
  int get pre => (sampleRate * .2).round();
  int get post => (sampleRate * .8).round();
  int get length => pre + post + 1;
  List<double> get sem => List.generate(
    length,
    (i) => accepted < 2 ? 0 : sqrt(_m2[i] / (accepted - 1) / accepted),
  );
  List<double> get corrected =>
      List.generate(length, (i) => mean[i] - pseudo[i]);
  double get windowAmplitude {
    if (accepted == 0) return 0;
    final a = pre + (sampleRate * .2).round(),
        b = pre + (sampleRate * .5).round();
    return mean.sublist(a, b + 1).reduce((a, b) => a + b) / (b - a + 1);
  }

  void _resetFilters() {
    hp = BiquadFilter.highPass(sampleRate, .5);
    lp = BiquadFilter.lowPass(sampleRate, 40);
    ecgHp = BiquadFilter.highPass(sampleRate, 1);
    ecgLp = BiquadFilter.lowPass(sampleRate, 45);
    notch = notchHz > 0 && notchHz < sampleRate / 2
        ? BiquadFilter.notch(sampleRate, notchHz)
        : null;
    _primed = false;
  }

  void _breakContinuity() {
    rejected += _pending.length;
    _pending.clear();
    _controls.clear();
    _eeg.clear();
    _raw.clear();
    _ecg.clear();
    _levels.clear();
    _base = _index + 1;
    _lastBeat = -100000;
    bpm = 0;
    _resetFilters();
  }

  void add(double eegUv, double ecgUv, DateTime timestamp) {
    final last = _lastTime;
    if (last != null &&
        timestamp.isBefore(
          last.add(Duration(microseconds: (500000 / sampleRate).round())),
        )) {
      return;
    }
    if (last != null &&
        timestamp.difference(last).inMicroseconds > 3000000 / sampleRate) {
      gaps++;
      _breakContinuity();
      quality = 'Signal gap: warming up';
    }
    _lastTime = timestamp;
    if (!eegUv.isFinite || !ecgUv.isFinite) {
      gaps++;
      _breakContinuity();
      quality = 'Invalid signal';
      return;
    }
    _index++;
    if (!_primed) {
      notch?.prime(eegUv);
      hp.prime(eegUv);
      lp.prime(0);
      ecgHp.prime(ecgUv);
      ecgLp.prime(0);
      _primed = true;
    }
    _raw.add(eegUv);
    _eeg.add(lp.process(hp.process(notch?.process(eegUv) ?? eegUv)));
    final cardiac = ecgLp.process(ecgHp.process(ecgUv));
    _ecg.add(cardiac);
    _levels.add(cardiac.abs());
    if (_levels.length > (sampleRate * 2).round()) _levels.removeAt(0);
    // Absolute local maximum handles either ECG polarity; two-second adaptation.
    if (_levels.length >= (sampleRate * 2).round() && _ecg.length >= 3) {
      final sorted = _levels.toList()..sort();
      final threshold = max(20.0, sorted[(sorted.length * .9).floor()] * 1.5);
      final n = _ecg.length;
      final peak = _ecg[n - 2].abs();
      final at = _index - 1;
      if (peak > threshold &&
          peak >= _ecg[n - 3].abs() &&
          peak > cardiac.abs() &&
          at - _lastBeat > sampleRate * .35) {
        beats++;
        final rr = (at - _lastBeat) / sampleRate;
        if (_lastBeat >= 0) {
          if (rr >= .4 && rr <= 1.5) {
            bpm = 60 / rr;
            // Mid-RR control from the reference pseudotrial procedure.
            _controls.add(_lastBeat + ((at - _lastBeat) / 2).round());
          } else {
            quality = 'Irregular RR interval';
          }
        }
        _lastBeat = at;
        if (at - _base >= sampleRate * 3) _pending.add(at);
      }
    }
    while (_pending.isNotEmpty && _index >= _pending.first + post) {
      _accumulate(_pending.removeAt(0));
    }
    while (_controls.isNotEmpty && _index >= _controls.first + post) {
      _accumulate(_controls.removeAt(0), control: true);
    }
    final keep = (sampleRate * 4).round();
    if (_eeg.length > keep) {
      _eeg.removeAt(0);
      _raw.removeAt(0);
      _ecg.removeAt(0);
      _base++;
    }
    if (_index - _lastBeat > sampleRate * 3 &&
        _levels.length >= sampleRate * 2) {
      bpm = 0;
      quality = 'No reliable ECG R-peaks';
    }
  }

  void _accumulate(int at, {bool control = false}) {
    final start = at - pre - _base, end = at + post - _base;
    if (start < 0 || end >= _eeg.length) {
      if (!control) rejected++;
      return;
    }
    final raw = _raw.sublist(start, end + 1);
    final rawPtp = raw.reduce(max) - raw.reduce(min);
    final epoch = _eeg.sublist(start, end + 1);
    final center = (length - 1) / 2;
    final avg = epoch.reduce((a, b) => a + b) / length;
    double numerator = 0, denominator = 0;
    for (var i = 0; i < length; i++) {
      numerator += (i - center) * (epoch[i] - avg);
      denominator += pow(i - center, 2);
    }
    for (var i = 0; i < length; i++) {
      epoch[i] -= avg + numerator / denominator * (i - center);
    }
    final ptp = epoch.reduce(max) - epoch.reduce(min);
    if (ptp > 150 || ptp < 1 || rawPtp > 250 || rawPtp < 1) {
      if (!control) {
        rejected++;
        quality = ptp < 1 || rawPtp < 1
            ? 'EEG flat / poor contact'
            : 'EEG artifact';
      }
      return;
    }
    final baseline = epoch.take(pre + 1).reduce((a, b) => a + b) / (pre + 1);
    if (control) {
      pseudoCount++;
      for (var i = 0; i < length; i++) {
        pseudo[i] += (epoch[i] - baseline - pseudo[i]) / pseudoCount;
      }
    } else {
      accepted++;
      for (var i = 0; i < length; i++) {
        final value = epoch[i] - baseline, delta = value - mean[i];
        mean[i] += delta / accepted;
        _m2[i] += delta * (value - mean[i]);
      }
      quality = accepted < 60
          ? 'Collecting: fewer than 60 clean epochs'
          : 'Usable epochs accumulating';
    }
  }

  void finish() {
    rejected += _pending.length;
    _pending.clear();
  }
}
