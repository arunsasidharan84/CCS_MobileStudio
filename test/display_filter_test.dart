import 'package:ccs_mobile_studio/core/eeg/display_filter.dart';
import 'package:ccs_mobile_studio/core/models/device_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('biosignal display configuration', () {
    test('recognizes EEG, EOG, EMG and non-electrophysiology channels', () {
      expect(biosignalTypeForLabel('Fz'), BiosignalType.eeg);
      expect(biosignalTypeForLabel('LOC-EOG'), BiosignalType.eog);
      expect(biosignalTypeForLabel('Chin EMG'), BiosignalType.emg);
      expect(biosignalTypeForLabel('ECG1'), BiosignalType.ecg);
      expect(biosignalTypeForLabel('PPG'), BiosignalType.ppg);
    });

    test('uses distinct default pass bands', () {
      const settings = DisplayFilterSettings();
      expect(settings.bandFor(BiosignalType.eeg), (0.3, 35.0));
      expect(settings.bandFor(BiosignalType.eog), (0.3, 15.0));
      expect(settings.bandFor(BiosignalType.emg), (10.0, 100.0));
      expect(settings.bandFor(BiosignalType.ppg), isNull);
    });

    test('uses explicit configured channel roles', () {
      expect(biosignalTypeForSignalType(SignalType.eog), BiosignalType.eog);
      expect(biosignalTypeForSignalType(SignalType.emg), BiosignalType.emg);
      expect(biosignalTypeForSignalType(SignalType.fnirs), BiosignalType.other);
    });
  });

  group('display montage', () {
    test('subtracts configured reference and updates display labels', () {
      const labels = ['Fz', 'C4', 'M1'];
      final values = DisplayMontage.apply(
        const [12.0, 7.0, 2.0],
        labels,
        const {'Fz': 'M1', 'C4': 'M1'},
      );
      expect(values, [10.0, 5.0, 2.0]);
      expect(DisplayMontage.labels(labels, const {'Fz': 'M1', 'C4': 'M1'}), [
        'Fz-M1',
        'C4-M1',
        'M1',
      ]);
    });

    test('ignores missing and self references', () {
      expect(
        DisplayMontage.apply(const [3.0, 2.0], const ['A', 'B'], const {
          'A': 'missing',
          'B': 'B',
        }),
        [3.0, 2.0],
      );
    });
  });

  test('PPG bypasses display filtering', () {
    final filter = DisplayFilter();
    final output = filter.process(
      const [123.5],
      labels: const ['PPG'],
      sampleRate: 250,
    );
    expect(output.single, 123.5);
  });

  test('EEG filter starts at the electrode baseline without a transient', () {
    final filter = DisplayFilter();
    final first = filter.process(
      const [50000.0],
      labels: const ['AF7'],
      channelTypes: const [SignalType.eeg],
      sampleRate: 250,
    );
    final second = filter.process(
      const [50000.0],
      labels: const ['AF7'],
      channelTypes: const [SignalType.eeg],
      sampleRate: 250,
    );
    expect(first.single.abs(), lessThan(1e-6));
    expect(second.single.abs(), lessThan(1e-6));
  });
}
