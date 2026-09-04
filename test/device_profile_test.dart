import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_mobile_studio/core/models/device_profile.dart';

void main() {
  test('built-in device profiles describe xAMP and Orbit clocks', () {
    final profiles = defaultDeviceProfiles();
    final xamp = profiles.firstWhere((profile) => profile.id == 'xamp_l10');
    final orbit = profiles.firstWhere((profile) => profile.id == 'orbit');

    expect(xamp.streams.single.channelCount, 16);
    expect(xamp.streams.single.sampleRate, 250);
    expect(orbit.streams.first.channelLabels, ['AF7', 'AF8']);
    expect(orbit.streams.first.sampleRate, 250);
    expect(orbit.streams.last.signalType, SignalType.ppg);
    expect(orbit.streams.last.sampleRate, 62.5);
  });

  test('generic mixed device profile survives JSON round trip', () {
    final source = DeviceProfile(
      id: 'mixed',
      name: 'Mixed EEG and fNIRS',
      transport: ConnectionTransport.lsl,
      protocol: DeviceProtocol.lsl,
      streams: [
        SignalStreamProfile(
          id: 'eeg',
          name: 'EEG',
          signalType: SignalType.eeg,
          sampleRate: 500,
          channelLabels: const ['C3', 'C4'],
        ),
        SignalStreamProfile(
          id: 'nirs',
          name: 'HbO/HbR',
          signalType: SignalType.fnirs,
          sampleRate: 10,
          channelLabels: const ['S1D1 HbO', 'S1D1 HbR'],
          unit: 'umol/L',
        ),
      ],
    );

    final restored = DeviceProfile.fromJson(source.toJson());
    expect(restored.transport, ConnectionTransport.lsl);
    expect(restored.streams.length, 2);
    expect(restored.streams.last.signalType, SignalType.fnirs);
    expect(restored.streams.last.unit, 'umol/L');
  });

  test('legacy mixed amplifier labels infer channel-specific roles', () {
    final stream = SignalStreamProfile.fromJson({
      'id': 'eeg',
      'name': 'PSG',
      'signalType': 'eeg',
      'sampleRate': 250,
      'channelLabels': ['C3', 'EOG1', 'Chin EMG', 'ECG'],
    });

    expect(stream.channelTypes, [
      SignalType.eeg,
      SignalType.eog,
      SignalType.emg,
      SignalType.ecg,
    ]);
  });

  test('explicit channel roles survive JSON round trip', () {
    final stream = SignalStreamProfile(
      id: 'mixed',
      name: 'Mixed',
      signalType: SignalType.eeg,
      sampleRate: 250,
      channelLabels: const ['A', 'B', 'C'],
      channelTypes: const [SignalType.eeg, SignalType.eog, SignalType.emg],
    );

    final restored = SignalStreamProfile.fromJson(stream.toJson());
    expect(restored.channelTypes, stream.channelTypes);
  });

  test('per-channel capture choices survive JSON and default to enabled', () {
    final stream = SignalStreamProfile(
      id: 'mixed',
      name: 'Mixed',
      signalType: SignalType.eeg,
      sampleRate: 250,
      channelLabels: const ['C3', 'EOG1', 'Unused'],
      channelEnabled: const [true, true, false],
    );

    final restored = SignalStreamProfile.fromJson(stream.toJson());
    expect(restored.channelEnabled, [true, true, false]);

    final legacy = SignalStreamProfile.fromJson({
      'id': 'legacy',
      'name': 'Legacy',
      'signalType': 'eeg',
      'sampleRate': 250,
      'channelLabels': ['C3', 'C4'],
    });
    expect(legacy.channelEnabled, [true, true]);
  });
}
