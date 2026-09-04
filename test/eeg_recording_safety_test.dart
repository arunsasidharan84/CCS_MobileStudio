import 'package:flutter_test/flutter_test.dart';

import 'package:ccs_mobile_studio/core/eeg/ads1299_scaling.dart';
import 'package:ccs_mobile_studio/core/eeg/edf_recorder.dart';
import 'package:ccs_mobile_studio/core/eeg/orbit_packet_decoder.dart';
import 'package:ccs_mobile_studio/core/models/sleep_score.dart';
import 'package:ccs_mobile_studio/core/widgets/waveform_painter.dart';
import 'package:ccs_mobile_studio/core/widgets/waveform_scale_snapshot.dart';

void main() {
  test('xAMP applies calibrated 100x gain after signed 24-bit decode', () {
    expect(Ads1299Scaling.signed24(0x00, 0x03, 0xE8), 1000);
    expect(Ads1299Scaling.signed24(0xFF, 0xFC, 0x18), -1000);
    expect(Ads1299Scaling.xampMicrovolts(1000), closeTo(-0.224, 1e-9));
    expect(Ads1299Scaling.xampMicrovolts(-1000), closeTo(0.224, 1e-9));
    expect(Ads1299Scaling.orbitMicrovolts(1000), closeTo(-22.4, 1e-9));
    expect(Ads1299Scaling.isAtRail(0x7FFFFF), isTrue);
    expect(Ads1299Scaling.isAtRail(1000), isFalse);
  });

  test(
    'EDF channel plan includes only enabled channels and matching labels',
    () {
      final selection = EdfRecorder.selectEnabledChannels(
        channelCount: 6,
        channelLabels: const ['Fz', 'Cz', 'C3', 'C4', 'EOG1', 'EMG1'],
        enabledChannels: const [true, false, true, false, true, false],
      );

      expect(selection.indices, [0, 2, 4]);
      expect(selection.labels, ['Fz', 'C3', 'EOG1']);
    },
  );

  test('ORBIT decoder converts both EEG channels and retains scalar PPG', () {
    final decoder = OrbitPacketDecoder();
    final samples = decoder.decode(
      '{A:[1000,-1000,500,0],B:[2000,-2000,250,0],E:10000,C:0}',
    );

    expect(samples, hasLength(4));
    expect(samples[0][0], closeTo(-22.4, 1e-9));
    expect(samples[0][1], closeTo(-44.8, 1e-9));
    expect(samples[1][0], closeTo(22.4, 1e-9));
    expect(samples.every((sample) => sample.length == 3), isTrue);
    expect(samples.every((sample) => sample[2].isFinite), isTrue);
    expect(samples.every((sample) => sample[2] == 0.0), isTrue);

    final changed = decoder.decode('{A:[0,0,0,0],B:[0,0,0,0],E:10100,C:0}');
    expect(changed.last[2], isNot(equals(0.0)));
  });

  test('ORBIT PPG is smoothly interpolated across 250 Hz EEG samples', () {
    final decoder = OrbitPacketDecoder();
    decoder.decode('{A:[0,0,0,0],B:[0,0,0,0],E:10000}');
    final next = decoder.decode('{A:[0,0,0,0],B:[0,0,0,0],E:12000}');
    expect(next[0][2], isNot(next[3][2]));
    expect(next[0][2], lessThan(next[3][2]));
  });

  test('ORBIT PPG contact step settles within two seconds', () {
    final decoder = OrbitPacketDecoder();
    decoder.filterPpg(10000);
    final response = <double>[
      for (var index = 0; index < 125; index++) decoder.filterPpg(12000),
    ];

    expect(response.first.abs(), greaterThan(1));
    expect(response.last.abs(), lessThan(response.first.abs() * 0.01));
  });

  test('artifact-dominated sleep epochs are exported as unscored', () {
    const result = SleepScoreResult(
      stage: SleepStage.rem,
      confidence: 0.78,
      epochIndex: 4,
      deltaPower: 1,
      thetaPower: 1,
      alphaPower: 1,
      betaPower: 1,
      artifactRatio: 0.78,
      probWake: 0.02,
      probN1: 0.05,
      probN2: 0.10,
      probN3: 0.05,
      probREM: 0.78,
    );

    expect(result.isReliable, isFalse);
    expect(result.toJson()['stage'], 'Unscored');
    expect(result.toJson()['modelStage'], 'REM');
    expect(result.toJson()['scoringValid'], isFalse);
  });

  test('PPG EDF metadata uses optical units and a non-EEG range', () {
    final metadata = EdfRecorder.signalMetadata(const ['AF7', 'AF8', 'PPG']);

    expect(metadata.physicalDimensions, const ['uV', 'uV', 'a.u.']);
    expect(metadata.transducers, const [
      'EEG electrode',
      'EEG electrode',
      'Optical PPG sensor',
    ]);
    expect(metadata.physicalMinimums, const [-15000.0, -15000.0, -32768.0]);
    expect(metadata.physicalMaximums, const [15000.0, 15000.0, 32767.0]);
  });

  test('mixed PSG EDF metadata preserves channel sensor roles', () {
    final metadata = EdfRecorder.signalMetadata(const [
      'C3',
      'EOG1',
      'Chin EMG',
      'ECG',
    ]);
    expect(metadata.transducers, const [
      'EEG electrode',
      'EOG electrode',
      'EMG electrode',
      'ECG electrode',
    ]);
  });

  test('two-channel ORBIT EEG keeps the wide anti-clipping EDF range', () {
    final metadata = EdfRecorder.signalMetadata(const ['AF7', 'AF8']);
    expect(metadata.physicalMinimums, everyElement(-15000.0));
    expect(metadata.physicalMaximums, everyElement(15000.0));
  });

  test('ORBIT EDF DC blocker removes baseline without losing changes', () {
    final blocker = OrbitEegDcBlocker();

    expect(blocker.process(-12000), 0);
    expect(blocker.process(-12000), closeTo(0, 1e-12));
    expect(blocker.process(-11900), closeTo(100, 1e-12));
    expect(blocker.process(-11900), closeTo(99.5, 1e-12));
  });

  test('disabling autoscale preserves the rendered signal scales', () {
    final fixed = WaveformScaleSnapshot.capture(
      eegUv: 93.25,
      ecgUv: 1840.5,
      ppg: 27.75,
    );

    expect(fixed.eegUv, 93.25);
    expect(fixed.ecgUv, 1840.5);
    expect(fixed.ppg, 27.75);
  });

  test(
    'autoscale ignores old filter startup and isolated recent artifacts',
    () {
      final trace = <double>[
        ...List<double>.filled(100, 10000),
        ...List<double>.generate(
          96,
          (index) => const [0.0, -50.0, 0.0, 50.0][index % 4],
        ),
        0,
        0,
        0,
        5000,
      ];

      expect(
        RobustWaveformAutoscale.amplitude(trace, visiblePoints: 200),
        closeTo(50, 0.001),
      );
    },
  );

  test('16-channel waveform canvas scrolls instead of compressing lanes', () {
    expect(
      WaveformPainter.canvasHeightForChannels(
        channelCount: 3,
        availableHeight: 400,
      ),
      400,
    );
    expect(
      WaveformPainter.canvasHeightForChannels(
        channelCount: 16,
        availableHeight: 400,
      ),
      1024,
    );
  });
}
