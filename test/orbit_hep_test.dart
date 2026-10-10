import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_mobile_studio/core/models/device_profile.dart';
import 'package:ccs_mobile_studio/core/models/eeg_sample.dart';
import 'package:ccs_mobile_studio/core/models/signal_stream_sample.dart';
import 'package:ccs_mobile_studio/modules/hep/orbit_hep_session.dart';

SignalStreamSample pulse(
  DateTime at,
  double value, {
  String device = 'orbit',
}) => SignalStreamSample(
  deviceProfileId: device,
  streamId: 'orbit_ppg',
  signalType: SignalType.ppg,
  channels: [value],
  channelLabels: ['PPG'],
  sampleRate: 62.5,
  timestamp: at,
  unit: 'a.u.',
  physicalMinimum: -32768,
  physicalMaximum: 32767,
);
void main() {
  test(
    'native PPG events accumulate independent frontal estimates in batches',
    () {
      final session = OrbitHepSession(
        deviceProfileId: 'orbit',
        ppgStreamId: 'orbit_ppg',
      );
      final start = DateTime(2026);
      // Orbit delivers EEG first, then native PPG for each packet batch.
      for (var batch = 0; batch < 30 * 250; batch += 20) {
        for (var i = batch; i < batch + 20; i++) {
          final t = i / 250;
          session.addEeg(
            EegSample(
              channels: [5 * sin(2 * pi * 7 * t), 0, 999999],
              sampleRate: 250,
              timestamp: start.add(Duration(microseconds: i * 4000)),
              source: 'Orbit',
            ),
          );
        }
        for (var i = batch; i < batch + 20; i += 4) {
          final t = i / 250;
          session.addPpg(
            pulse(
              start.add(Duration(microseconds: i * 4000)),
              1000 * exp(-pow(((t % .8) - .2) / .08, 2)),
            ),
          );
        }
      }
      expect(session.pulseCount, greaterThan(25));
      expect(session.channels[0].accepted, greaterThan(20));
      expect(session.channels[0].bpm, closeTo(75, 3));
      expect(session.channels[0].pseudoCount, greaterThan(20));
      expect(session.channels[1].accepted, 0);
      expect(session.channels[1].rejected, greaterThan(20));
      final before = session.pulseCount;
      session.addPpg(
        pulse(start.add(const Duration(seconds: 31)), 1000, device: 'other'),
      );
      expect(session.pulseCount, before);
      expect(
        session.lastPpg!.isBefore(start.add(const Duration(seconds: 31))),
        isTrue,
      );
      session.addPpg(pulse(start.add(const Duration(seconds: 31)), 0));
      expect(session.channels[0].gaps, greaterThan(0));
      expect(session.channels[0].bpm, 0);
    },
  );
  test('flat PPG and repeated samples do not create cardiac events', () {
    final session = OrbitHepSession(
      deviceProfileId: 'orbit',
      ppgStreamId: 'orbit_ppg',
    );
    for (var i = 0; i < 2500; i++) {
      final at = DateTime(2026).add(Duration(microseconds: i * 4000));
      session.addEeg(
        EegSample(
          channels: [5 * sin(i / 10), 5 * cos(i / 10)],
          sampleRate: 250,
          timestamp: at,
          source: 'Orbit',
        ),
      );
      if (i % 4 == 0) {
        session.addPpg(pulse(at, 100));
        session.addPpg(pulse(at, 100));
      }
    }
    expect(session.pulseCount, 0);
    expect(session.channels.every((e) => e.accepted == 0), isTrue);
  });
}
