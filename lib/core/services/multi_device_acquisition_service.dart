import 'dart:async';

import 'package:flutter/foundation.dart';

import '../eeg/acquisition_service.dart';
import '../models/device_profile.dart';
import '../models/signal_stream_sample.dart';
import 'alert_service.dart';
import 'settings_service.dart';

/// Owns additional direct Bluetooth acquisitions while preserving the original
/// acquisition service as the primary device used by sleep-scoring modules.
class MultiDeviceAcquisitionService extends ChangeNotifier {
  AcquisitionService? _primary;
  SettingsService? _settings;
  AlertService? _alerts;
  AcquisitionService? _scanner;
  final Map<String, AcquisitionService> _secondary = {};
  final Map<String, AcquisitionService> _connectingSecondary = {};
  final Map<String, List<StreamSubscription<dynamic>>> _subscriptions = {};
  final Set<String> _pendingDeviceIds = {};
  final _samples = StreamController<SignalStreamSample>.broadcast();

  Stream<SignalStreamSample> get samples => _samples.stream;
  List<AcquisitionService> get secondaryServices =>
      List.unmodifiable(_secondary.values);
  List<AcquisitionService> get readySecondaryServices => _secondary.values
      .where((service) => service.isStreamReady)
      .toList(growable: false);
  Map<String, AcquisitionService> get secondaryDevices =>
      Map.unmodifiable(_secondary);

  List<EegDevice> get discoveredDevices {
    final devices = <EegDevice>{
      ...?_primary?.discoveredDevices,
      ...?_scanner?.discoveredDevices,
    };
    return devices.toList(growable: false);
  }

  Map<String, SignalStreamProfile> get connectedStreamProfiles {
    final result = <String, SignalStreamProfile>{};
    for (final entry in _secondary.entries) {
      final service = entry.value;
      if (!service.isStreamReady) continue;
      final labels = service.displayChannelLabels(service.channelCount);
      final source = service.primaryRecordingStream;
      result['${entry.key}:primary'] = SignalStreamProfile(
        id: 'primary',
        name: service.connectedDeviceLabel,
        signalType: SignalType.eeg,
        sampleRate: service.sampleRate,
        channelLabels: labels,
        channelTypes: service.displayChannelTypes(service.channelCount),
        channelEnabled: service.recordingEnabledChannels(null),
        unit: source?.unit ?? 'uV',
        physicalMinimum: source?.physicalMinimum ?? -3000,
        physicalMaximum: source?.physicalMaximum ?? 3000,
      );
    }
    return result;
  }

  bool get isScanning =>
      (_scanner?.currentState == AcquisitionState.scanning) ||
      (_primary?.currentState == AcquisitionState.scanning);
  bool get isBusy =>
      isScanning ||
      _pendingDeviceIds.isNotEmpty ||
      _connectingSecondary.isNotEmpty ||
      (_primary?.currentState == AcquisitionState.connecting) ||
      (_primary?.isRecovering ?? false) ||
      _secondary.values.any((service) => service.isRecovering);

  bool isDeviceConnectedOrConnecting(String deviceId) {
    return _primary?.connectedDeviceId == deviceId ||
        _secondary.containsKey(deviceId) ||
        _connectingSecondary.containsKey(deviceId) ||
        _pendingDeviceIds.contains(deviceId);
  }

  void update(
    AcquisitionService primary,
    SettingsService settings,
    AlertService alerts,
  ) {
    _primary = primary;
    _settings = settings;
    _alerts = alerts;
    for (final service in _secondary.values) {
      service
        ..updateSettings(settings)
        ..updateAlertService(alerts);
    }
  }

  Future<void> scan() async {
    final primary = _primary;
    if (primary == null) return;
    if (primary.currentState != AcquisitionState.streaming) {
      await primary.scan(autoConnect: false);
      return;
    }
    final scanner = _scanner ??= AcquisitionService();
    scanner
      ..updateSettings(_settings)
      ..updateAlertService(_alerts);
    scanner.removeListener(notifyListeners);
    scanner.addListener(notifyListeners);
    await scanner.scan(autoConnect: false);
  }

  Future<void> connect(EegDevice device) async {
    final primary = _primary;
    if (primary == null) return;
    if (isDeviceConnectedOrConnecting(device.id)) {
      debugPrint(
        '[MultiDevice] Ignoring duplicate connection request for ${device.name}.',
      );
      return;
    }
    if (primary.currentState == AcquisitionState.connecting) return;
    // Android BLE scanning competes for controller time with high-rate GATT
    // notifications. Stop the shared scanner before opening either link.
    await _scanner?.stopScan();
    _pendingDeviceIds.add(device.id);
    notifyListeners();
    if (!primary.isStreamReady) {
      await primary.connect(device);
      _pendingDeviceIds.remove(device.id);
      notifyListeners();
      return;
    }

    final service = AcquisitionService()
      ..updateSettings(_settings)
      ..updateAlertService(_alerts);
    _connectingSecondary[device.id] = service;
    service.addListener(notifyListeners);
    _subscriptions[device.id] = <StreamSubscription<dynamic>>[
      service.samples.listen((sample) {
        final count = sample.channels.length;
        final profile = service.primaryRecordingStream;
        _samples.add(
          SignalStreamSample(
            deviceProfileId: device.profileId ?? device.id,
            streamId: '${device.id}:primary',
            signalType: SignalType.eeg,
            channels: sample.channels,
            channelLabels: service.displayChannelLabels(count),
            channelTypes: service.displayChannelTypes(count),
            sampleRate: service.sampleRate,
            timestamp: sample.timestamp,
            unit: profile?.unit ?? 'uV',
            physicalMinimum: profile?.physicalMinimum ?? -3000,
            physicalMaximum: profile?.physicalMaximum ?? 3000,
          ),
        );
      }),
      service.streamSamples.listen((sample) {
        _samples.add(
          SignalStreamSample(
            deviceProfileId: sample.deviceProfileId,
            streamId: '${device.id}:${sample.streamId}',
            signalType: sample.signalType,
            channels: sample.channels,
            channelLabels: sample.channelLabels,
            channelTypes: sample.channelTypes,
            sampleRate: sample.sampleRate,
            timestamp: sample.timestamp,
            unit: sample.unit,
            physicalMinimum: sample.physicalMinimum,
            physicalMaximum: sample.physicalMaximum,
          ),
        );
      }),
    ];
    try {
      final connected = await service.connect(device);
      // Disconnect all may have cancelled and disposed this candidate while
      // connect() was waiting for its first valid frame.
      if (_connectingSecondary.remove(device.id) != service) return;
      if (connected) {
        _secondary[device.id] = service;
      } else {
        await _disposeCandidate(device.id, service);
      }
    } finally {
      _connectingSecondary.remove(device.id);
      _pendingDeviceIds.remove(device.id);
      notifyListeners();
    }
  }

  Future<void> _disposeCandidate(
    String deviceId,
    AcquisitionService service,
  ) async {
    for (final subscription
        in _subscriptions.remove(deviceId) ?? const <StreamSubscription>[]) {
      await subscription.cancel();
    }
    service.removeListener(notifyListeners);
    await service.disconnect();
    service.dispose();
  }

  Future<void> disconnect(String deviceId) async {
    final service = _secondary.remove(deviceId);
    for (final subscription
        in _subscriptions.remove(deviceId) ?? const <StreamSubscription>[]) {
      await subscription.cancel();
    }
    if (service != null) {
      service.removeListener(notifyListeners);
      await service.disconnect();
      service.dispose();
    }
    notifyListeners();
  }

  Future<void> disconnectAll({bool includePrimary = true}) async {
    _pendingDeviceIds.clear();
    final connecting = Map<String, AcquisitionService>.of(_connectingSecondary);
    _connectingSecondary.clear();
    for (final entry in connecting.entries) {
      await _disposeCandidate(entry.key, entry.value);
    }
    final ids = _secondary.keys.toList(growable: false);
    for (final id in ids) {
      await disconnect(id);
    }
    if (includePrimary) {
      await _primary?.disconnect();
    }
    await _scanner?.disconnect();
    _alerts?.stopBeeping();
    notifyListeners();
  }

  @override
  void dispose() {
    for (final subscriptions in _subscriptions.values) {
      for (final subscription in subscriptions) {
        unawaited(subscription.cancel());
      }
    }
    for (final service in _secondary.values) {
      service.removeListener(notifyListeners);
      service.dispose();
    }
    for (final service in _connectingSecondary.values) {
      service.removeListener(notifyListeners);
      service.dispose();
    }
    _scanner?.removeListener(notifyListeners);
    _scanner?.dispose();
    _samples.close();
    super.dispose();
  }
}
