import 'package:ccs_mobile_studio/modules/nidra/sleep_channel_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('selects benchmark derivation when C3 and M1 are present', () {
    final selection = SleepChannelSelection.fromLabels(const [
      'Fz',
      'C3',
      'C4',
      'M1',
      'EOG1',
    ]);
    expect(selection?.derivationLabel, 'C3-M1');
    expect(selection?.signalIndex, 1);
    expect(selection?.referenceIndex, 3);
  });

  test('uses another EEG channel when C3 is absent', () {
    final selection = SleepChannelSelection.fromLabels(const [
      'EOG1',
      'C4',
      'Fz',
      'M1',
      'EMG1',
    ]);
    expect(selection?.derivationLabel, 'C4-M1');
  });

  test('uses another mastoid reference when M1 is absent', () {
    final selection = SleepChannelSelection.fromLabels(const [
      'Fz',
      'C3',
      'M2',
      'EOG1',
    ]);
    expect(selection?.derivationLabel, 'C3-M2');
  });

  test('uses an unreferenced EEG when no mastoid channel exists', () {
    final selection = SleepChannelSelection.fromLabels(const [
      'EOG1',
      'EMG1',
      'Fz',
      'PPG',
    ]);
    expect(selection?.derivationLabel, 'Fz');
  });

  test('does not mistake non-EEG channels for EEG', () {
    expect(
      SleepChannelSelection.fromLabels(const [
        'EOG1',
        'EMG1',
        'ECG',
        'PPG',
        'EDF Annotations',
      ]),
      isNull,
    );
  });

  test('explicit scoring channel respects enabled capture channels', () {
    final selection = SleepChannelSelection.fromLabels(
      const ['Fz', 'Cz', 'C3', 'M1'],
      enabledChannels: const [true, false, false, true],
      preferredSignalLabel: 'C3',
      preferredReferenceLabel: '__none__',
    );

    expect(selection?.signalLabel, 'Fz');
    expect(selection?.referenceLabel, isNull);
  });

  test('explicit montage selects signal and reference by label', () {
    final selection = SleepChannelSelection.fromLabels(
      const ['Fz', 'Cz', 'M1'],
      enabledChannels: const [true, true, true],
      preferredSignalLabel: 'Fz',
      preferredReferenceLabel: 'M1',
    );

    expect(selection?.signalIndex, 0);
    expect(selection?.referenceIndex, 2);
    expect(selection?.derivationLabel, 'Fz-M1');
  });
}
