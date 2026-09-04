enum ConnectionTransport { bluetoothClassic, bluetoothLe, lsl, synthetic }

enum DeviceProtocol { xampBinary, orbitJson, delimitedText, lsl, synthetic }

enum SignalType { eeg, eog, emg, ecg, ppg, fnirs, marker, auxiliary }

extension ConnectionTransportLabel on ConnectionTransport {
  String get label => switch (this) {
    ConnectionTransport.bluetoothClassic => 'Bluetooth Classic',
    ConnectionTransport.bluetoothLe => 'Bluetooth LE',
    ConnectionTransport.lsl => 'Lab Streaming Layer (LSL)',
    ConnectionTransport.synthetic => 'Synthetic',
  };
}

extension DeviceProtocolLabel on DeviceProtocol {
  String get label => switch (this) {
    DeviceProtocol.xampBinary => 'xAMP binary (ADS1299)',
    DeviceProtocol.orbitJson => 'Orbit JSON',
    DeviceProtocol.delimitedText => 'Delimited numeric text',
    DeviceProtocol.lsl => 'LSL samples',
    DeviceProtocol.synthetic => 'Synthetic samples',
  };
}

extension SignalTypeLabel on SignalType {
  String get label => switch (this) {
    SignalType.eeg => 'EEG',
    SignalType.eog => 'EOG',
    SignalType.emg => 'EMG',
    SignalType.ecg => 'ECG',
    SignalType.ppg => 'PPG',
    SignalType.fnirs => 'fNIRS',
    SignalType.marker => 'Markers',
    SignalType.auxiliary => 'Auxiliary',
  };
}

class SignalStreamProfile {
  SignalStreamProfile({
    required this.id,
    required this.name,
    required this.signalType,
    required this.sampleRate,
    required List<String> channelLabels,
    List<SignalType>? channelTypes,
    List<bool>? channelEnabled,
    this.enabled = true,
    this.unit = 'uV',
    this.physicalMinimum = -3000,
    this.physicalMaximum = 3000,
    this.lslName = '',
    this.lslType = '',
  }) : channelLabels = List<String>.from(channelLabels),
       channelTypes = normalizeChannelTypes(channelLabels, channelTypes),
       channelEnabled = normalizeChannelEnabled(channelLabels, channelEnabled);

  String id;
  String name;
  SignalType signalType;
  double sampleRate;
  List<String> channelLabels;
  List<SignalType> channelTypes;
  List<bool> channelEnabled;
  bool enabled;
  String unit;
  double physicalMinimum;
  double physicalMaximum;
  String lslName;
  String lslType;

  int get channelCount => channelLabels.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'signalType': signalType.name,
    'sampleRate': sampleRate,
    'channelLabels': channelLabels,
    'channelTypes': channelTypes.map((type) => type.name).toList(),
    'channelEnabled': channelEnabled,
    'enabled': enabled,
    'unit': unit,
    'physicalMinimum': physicalMinimum,
    'physicalMaximum': physicalMaximum,
    'lslName': lslName,
    'lslType': lslType,
  };

  factory SignalStreamProfile.fromJson(Map<String, dynamic> json) {
    final typeName = json['signalType'] as String? ?? 'eeg';
    return SignalStreamProfile(
      id: json['id'] as String? ?? 'stream',
      name: json['name'] as String? ?? 'Signal stream',
      signalType: SignalType.values.firstWhere(
        (value) => value.name == typeName,
        orElse: () => SignalType.auxiliary,
      ),
      sampleRate: ((json['sampleRate'] as num?)?.toDouble() ?? 250).clamp(
        0.1,
        10000,
      ),
      channelLabels: List<String>.from(
        json['channelLabels'] as List? ?? const ['Ch 1'],
      ),
      channelTypes: (json['channelTypes'] as List?)
          ?.map(
            (name) => SignalType.values.firstWhere(
              (type) => type.name == name,
              orElse: () => SignalType.auxiliary,
            ),
          )
          .toList(),
      channelEnabled: (json['channelEnabled'] as List?)
          ?.map((value) => value == true)
          .toList(),
      enabled: json['enabled'] as bool? ?? true,
      unit: json['unit'] as String? ?? 'uV',
      physicalMinimum: (json['physicalMinimum'] as num?)?.toDouble() ?? -3000,
      physicalMaximum: (json['physicalMaximum'] as num?)?.toDouble() ?? 3000,
      lslName: json['lslName'] as String? ?? '',
      lslType: json['lslType'] as String? ?? '',
    );
  }

  static List<SignalType> normalizeChannelTypes(
    List<String> labels,
    List<SignalType>? configured,
  ) {
    return List<SignalType>.generate(labels.length, (index) {
      if (configured != null && index < configured.length) {
        return configured[index];
      }
      return inferChannelType(labels[index]);
    }, growable: false);
  }

  static List<bool> normalizeChannelEnabled(
    List<String> labels,
    List<bool>? configured,
  ) {
    return List<bool>.generate(
      labels.length,
      (index) => configured == null || index >= configured.length
          ? true
          : configured[index],
      growable: false,
    );
  }

  static SignalType inferChannelType(String label) {
    final value = label.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (value.contains('EOG') ||
        value.startsWith('LOC') ||
        value.startsWith('ROC')) {
      return SignalType.eog;
    }
    if (value.contains('EMG') ||
        value.contains('CHIN') ||
        value.contains('MENTAL')) {
      return SignalType.emg;
    }
    if (value.contains('ECG') || value.contains('EKG')) return SignalType.ecg;
    if (value.contains('PPG') || value.contains('PLETH')) return SignalType.ppg;
    if (value.contains('MARK') ||
        value.contains('TRIGGER') ||
        value.contains('ANNOT')) {
      return SignalType.marker;
    }
    return SignalType.eeg;
  }

  void synchronizeChannelTypes() {
    channelTypes = normalizeChannelTypes(channelLabels, channelTypes);
    channelEnabled = normalizeChannelEnabled(channelLabels, channelEnabled);
  }
}

class DeviceProfile {
  DeviceProfile({
    required this.id,
    required this.name,
    required this.transport,
    required this.protocol,
    required List<SignalStreamProfile> streams,
    this.enabled = true,
    this.advertisedNamePattern = '',
    this.addressPattern = '',
    this.autoConnect = false,
    this.startCommand = '',
    this.delimiter = ',',
  }) : streams = List<SignalStreamProfile>.from(streams);

  String id;
  String name;
  ConnectionTransport transport;
  DeviceProtocol protocol;
  List<SignalStreamProfile> streams;
  bool enabled;
  String advertisedNamePattern;
  String addressPattern;
  bool autoConnect;
  String startCommand;
  String delimiter;

  Iterable<SignalStreamProfile> get enabledStreams =>
      streams.where((stream) => stream.enabled);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'transport': transport.name,
    'protocol': protocol.name,
    'streams': streams.map((stream) => stream.toJson()).toList(),
    'enabled': enabled,
    'advertisedNamePattern': advertisedNamePattern,
    'addressPattern': addressPattern,
    'autoConnect': autoConnect,
    'startCommand': startCommand,
    'delimiter': delimiter,
  };

  factory DeviceProfile.fromJson(Map<String, dynamic> json) {
    final transportName = json['transport'] as String? ?? 'bluetoothLe';
    final protocolName = json['protocol'] as String? ?? 'delimitedText';
    return DeviceProfile(
      id: json['id'] as String? ?? 'other',
      name: json['name'] as String? ?? 'Other device',
      transport: ConnectionTransport.values.firstWhere(
        (value) => value.name == transportName,
        orElse: () => ConnectionTransport.bluetoothLe,
      ),
      protocol: DeviceProtocol.values.firstWhere(
        (value) => value.name == protocolName,
        orElse: () => DeviceProtocol.delimitedText,
      ),
      streams: (json['streams'] as List? ?? const [])
          .whereType<Map>()
          .map(
            (value) =>
                SignalStreamProfile.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList(),
      enabled: json['enabled'] as bool? ?? true,
      advertisedNamePattern: json['advertisedNamePattern'] as String? ?? '',
      addressPattern: json['addressPattern'] as String? ?? '',
      autoConnect: json['autoConnect'] as bool? ?? false,
      startCommand: json['startCommand'] as String? ?? '',
      delimiter: json['delimiter'] as String? ?? ',',
    );
  }
}

List<DeviceProfile> defaultDeviceProfiles() => [
  DeviceProfile(
    id: 'xamp_l10',
    name: 'xAMP-L10',
    transport: ConnectionTransport.bluetoothLe,
    protocol: DeviceProtocol.xampBinary,
    advertisedNamePattern: 'AXXSPU',
    startCommand: 'rxs7',
    streams: [
      SignalStreamProfile(
        id: 'xamp_eeg',
        name: 'EEG',
        signalType: SignalType.eeg,
        sampleRate: 250,
        channelLabels: const [
          'Fp1',
          'Fp2',
          'F3',
          'F4',
          'C3',
          'Cz',
          'C4',
          'P3',
          'Pz',
          'P4',
          'O1',
          'Oz',
          'O2',
          'F7',
          'F8',
          'T3',
        ],
        channelTypes: const [
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
          SignalType.eeg,
        ],
        unit: 'uV',
        physicalMinimum: -3000,
        physicalMaximum: 3000,
      ),
    ],
  ),
  DeviceProfile(
    id: 'orbit',
    name: 'Orbit',
    transport: ConnectionTransport.bluetoothLe,
    protocol: DeviceProtocol.orbitJson,
    advertisedNamePattern: 'ORBIT_',
    startCommand: '9',
    streams: [
      SignalStreamProfile(
        id: 'orbit_eeg',
        name: 'EEG',
        signalType: SignalType.eeg,
        sampleRate: 250,
        channelLabels: const ['AF7', 'AF8'],
        unit: 'uV',
        physicalMinimum: -15000,
        physicalMaximum: 15000,
      ),
      SignalStreamProfile(
        id: 'orbit_ppg',
        name: 'PPG',
        signalType: SignalType.ppg,
        sampleRate: 62.5,
        channelLabels: const ['PPG'],
        unit: 'a.u.',
        physicalMinimum: -32768,
        physicalMaximum: 32767,
      ),
    ],
  ),
  DeviceProfile(
    id: 'other',
    name: 'Other device',
    enabled: false,
    transport: ConnectionTransport.bluetoothLe,
    protocol: DeviceProtocol.delimitedText,
    streams: [
      SignalStreamProfile(
        id: 'other_eeg',
        name: 'Signal stream',
        signalType: SignalType.eeg,
        sampleRate: 250,
        channelLabels: const ['Ch 1'],
      ),
    ],
  ),
];
