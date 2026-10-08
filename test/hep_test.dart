import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_mobile_studio/modules/hep/hep_engine.dart';

void main() {
  test('rejects unsupported sample rates', () {
    expect(() => HepEngine(60), throwsArgumentError);
  });
  test('streaming ECG produces baseline corrected HEP and controls', () {
    final e = HepEngine(250);
    final start = DateTime(2026);
    for (var i = 0; i < 250 * 30; i++) {
      final t = i / 250;
      final phase = t % .8;
      final ecg = 1000 * exp(-pow((phase - .1) / .012, 2));
      final eeg =
          4 * sin(2 * pi * 7 * t) + 3 * exp(-pow((phase - .4) / .08, 2));
      e.add(eeg, ecg, start.add(Duration(microseconds: i * 4000)));
    }
    expect(e.accepted, greaterThan(20));
    expect(e.pseudoCount, greaterThan(20));
    expect(e.bpm, closeTo(75, 3));
    expect(
      e.mean.take(e.pre + 1).reduce((a, b) => a + b) / (e.pre + 1),
      closeTo(0, 1e-8),
    );
    expect(e.sem.every((v) => v.isFinite), isTrue);
    e.add(0, 0, start.add(const Duration(seconds: 40)));
    expect(e.gaps, 1);
  });
  test('flat EEG does not become an accepted HEP', () {
    final e = HepEngine(250);
    for (var i = 0; i < 5000; i++) {
      final phase = (i / 250) % .8;
      e.add(
        0,
        1000 * exp(-pow((phase - .1) / .012, 2)),
        DateTime(2026).add(Duration(microseconds: i * 4000)),
      );
    }
    expect(e.accepted, 0);
    expect(e.rejected, greaterThan(0));
  });
}
