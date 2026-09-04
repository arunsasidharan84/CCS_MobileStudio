/// Configuration for connecting to an EEG stream via Lab Streaming Layer.
class LslConfig {
  const LslConfig({
    this.eegStreamName = '',
    this.eegStreamType = 'EEG',
    this.nirsStreamName = '',
    this.nirsStreamType = 'NIRS',
    this.resolveTimeoutSeconds = 5.0,
  });

  final String eegStreamName;
  final String eegStreamType;
  final String nirsStreamName;
  final String nirsStreamType;
  final double resolveTimeoutSeconds;

  LslConfig copyWith({
    String? eegStreamName,
    String? eegStreamType,
    String? nirsStreamName,
    String? nirsStreamType,
    double? resolveTimeoutSeconds,
  }) {
    return LslConfig(
      eegStreamName: eegStreamName ?? this.eegStreamName,
      eegStreamType: eegStreamType ?? this.eegStreamType,
      nirsStreamName: nirsStreamName ?? this.nirsStreamName,
      nirsStreamType: nirsStreamType ?? this.nirsStreamType,
      resolveTimeoutSeconds:
          resolveTimeoutSeconds ?? this.resolveTimeoutSeconds,
    );
  }

  Map<String, dynamic> toJson() => {
    'eegStreamName': eegStreamName,
    'eegStreamType': eegStreamType,
    'nirsStreamName': nirsStreamName,
    'nirsStreamType': nirsStreamType,
    'resolveTimeoutSeconds': resolveTimeoutSeconds,
  };

  factory LslConfig.fromJson(Map<String, dynamic> json) => LslConfig(
    eegStreamName: (json['eegStreamName'] as String?) ?? '',
    eegStreamType: (json['eegStreamType'] as String?) ?? 'EEG',
    nirsStreamName: (json['nirsStreamName'] as String?) ?? '',
    nirsStreamType: (json['nirsStreamType'] as String?) ?? 'NIRS',
    resolveTimeoutSeconds:
        (json['resolveTimeoutSeconds'] as num?)?.toDouble() ?? 5.0,
  );
}
