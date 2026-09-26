import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart'
    as classic;
import 'package:permission_handler/permission_handler.dart';

import '../models/eeg_sample.dart';
import '../models/device_profile.dart';
import '../models/signal_stream_sample.dart';
import '../services/alert_service.dart';
import '../services/settings_service.dart';
import 'ads1299_scaling.dart';
import 'orbit_packet_decoder.dart';
import 'orbit_sample_clock.dart';

enum DeviceKind { orbit, epidome, generic, synthetic }

enum AcquisitionState { disconnected, scanning, connecting, streaming }

class EegDevice {
  const EegDevice({
    required this.name,
    required this.id,
    required this.kind,
    required this.isBle,
    this.profileId,
  });

  final String name;
  final String id;
  final DeviceKind kind;
  final bool isBle;
  final String? profileId;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is EegDevice && other.id == id && other.isBle == isBle;
  }

  @override
  int get hashCode => Object.hash(id, isBle);
}

class AcquisitionService extends ChangeNotifier {
  String orbitPrefix = 'ORBIT_';
  String xampPrefix = 'AXXSPU00002'; // Updated default per user confirmation!

  int reconnectMaxAttempts = 0;
  int reconnectIntervalSec = 5;
  bool reconnectBeepEnabled = true;
  int disconnectionTimeoutSeconds = 5;

  int _reconnectAttempts = 0;
  final _maxRetriesReachedController = StreamController<void>.broadcast();

  Stream<void> get maxRetriesReached => _maxRetriesReachedController.stream;

  static const String _nordicUartServiceUuid =
      '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _nordicUartRxUuid =
      '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _nordicUartTxUuid =
      '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
  static const String _hm10ServiceUuid = 'ffe0';
  static const String _hm10DataUuid = 'ffe1';
  static const String _tiDataStreamServiceUuid =
      'f000c0c0-0451-4000-b000-000000000000';
  static const String _tiDataStreamWriteUuid =
      'f000c0c1-0451-4000-b000-000000000000';
  static const String _tiDataStreamNotifyUuid =
      'f000c0c2-0451-4000-b000-000000000000';
  static const int _epidomeFrameHeader = 0xAA;
  static const int _epidomeFrameHeaderLength = 3;
  static const int _epidomeChannelCount = 16;
  static const int _epidomeFrameLength =
      _epidomeFrameHeaderLength + _epidomeChannelCount * 3;

  final _state = StreamController<AcquisitionState>.broadcast();
  final _samples = StreamController<EegSample>.broadcast();
  final _streamSamples = StreamController<SignalStreamSample>.broadcast();
  final _devices = StreamController<List<EegDevice>>.broadcast();

  StreamSubscription<ble.BluetoothConnectionState>? _bleConnectionStateSub;

  AcquisitionState _currentState = AcquisitionState.disconnected;
  final List<EegDevice> _seenDevices = [];
  final List<int> _classicBuffer = [];
  final List<int> _bleBuffer = [];
  String _orbitTextBuffer = '';
  int _orbitAsciiSampleIndex = 0;
  final OrbitSampleClock _orbitEegClock = OrbitSampleClock();
  final OrbitSampleClock _orbitPpgClock = OrbitSampleClock();
  final _random = Random();
  final OrbitPacketDecoder _orbitDecoder = OrbitPacketDecoder();

  StreamSubscription<classic.BluetoothDiscoveryResult>? _classicScanSub;
  StreamSubscription<List<ble.ScanResult>>? _bleScanSub;
  StreamSubscription<Uint8List>? _classicInputSub;
  StreamSubscription<List<int>>? _bleNotifySub;
  classic.BluetoothConnection? _classicConnection;
  ble.BluetoothDevice? _bleDevice;
  Timer? _syntheticTimer;
  double _syntheticT = 0.0;
  EegDevice? _lastConnectedDevice;
  bool _autoReconnectEnabled = false;
  Timer? _reconnectTimer;
  bool _reconnectInProgress = false;
  bool _handlingUnexpectedDisconnect = false;
  bool _hasEverStreamed = false;
  int _deliveredSampleCount = 0;
  DateTime? _rateWindowStarted;
  int _rateWindowSamples = 0;
  int _rateWindowNotifications = 0;
  int _rateWindowBytes = 0;
  double? _deliveredSampleRate;
  final List<int> _xampRailRuns = List.filled(_epidomeChannelCount, 0);
  final Set<int> _xampSaturatedChannels = {};
  Completer<void>? _firstSampleCompleter;
  bool _connectionCancelled = false;
  AlertService? _alertService;
  SettingsService? _settings;

  void updateAlertService(AlertService? alertService) {
    _alertService = alertService;
  }

  void updateSettings(SettingsService? settings) {
    if (settings != null) {
      _settings = settings;
      xampPrefix = settings.xampPrefix;
      orbitPrefix = settings.orbitPrefix;
      reconnectMaxAttempts = settings.maxReconnectAttempts;
      reconnectIntervalSec = settings.reconnectIntervalSec;
      reconnectBeepEnabled = settings.reconnectBeepEnabled;
      disconnectionTimeoutSeconds = settings.disconnectionTimeoutSeconds;
    }
  }

  // Watchdog timer for silent freezes
  Timer? _watchdogTimer;
  DateTime _lastSampleTime = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<AcquisitionState> get state => _state.stream;
  Stream<EegSample> get samples => _samples.stream;
  Stream<SignalStreamSample> get streamSamples => _streamSamples.stream;
  Stream<List<EegDevice>> get devices => _devices.stream;
  List<EegDevice> get discoveredDevices => List.unmodifiable(_seenDevices);
  AcquisitionState get currentState => _currentState;
  String get connectedDeviceLabel => _lastConnectedDevice?.name ?? 'EEG';
  String? get connectedDeviceId => _lastConnectedDevice?.id;
  DeviceKind? get connectedDeviceKind => _lastConnectedDevice?.kind;
  DeviceProfile? get connectedDeviceProfile => _activeProfile;
  bool get hasReceivedSamples => _deliveredSampleCount > 0;
  bool get isStreamReady =>
      _currentState == AcquisitionState.streaming && hasReceivedSamples;
  bool get isRecovering =>
      _reconnectInProgress || (_reconnectTimer?.isActive ?? false);
  double? get deliveredSampleRate => _deliveredSampleRate;
  List<String> get adcSaturatedChannelLabels {
    final labels = displayChannelLabels(_epidomeChannelCount);
    return _xampSaturatedChannels
        .map(
          (index) => index < labels.length ? labels[index] : 'Ch ${index + 1}',
        )
        .toList(growable: false);
  }

  DeviceProfile? get _activeProfile {
    final id = _lastConnectedDevice?.profileId;
    if (id == null) return null;
    return _settings?.profileById(id);
  }

  SignalStreamProfile? get primaryRecordingStream {
    final streams = _activeProfile?.enabledStreams.toList() ?? const [];
    for (final stream in streams) {
      if (stream.signalType == SignalType.eeg ||
          stream.signalType == SignalType.ecg) {
        return stream;
      }
    }
    return streams.isEmpty ? null : streams.first;
  }

  double get sampleRate =>
      primaryRecordingStream?.sampleRate ??
      switch (_lastConnectedDevice?.kind) {
        DeviceKind.epidome => 250.0,
        DeviceKind.orbit => 250.0,
        DeviceKind.generic => 250.0,
        DeviceKind.synthetic => 250.0,
        null => 250.0,
      };

  int get channelCount {
    if (_lastConnectedDevice?.kind == DeviceKind.orbit &&
        (_settings?.combineCompatibleStreams ?? true)) {
      return channelLabels.length;
    }
    return primaryRecordingStream?.channelCount ??
        switch (_lastConnectedDevice?.kind) {
          DeviceKind.epidome => 16,
          DeviceKind.orbit => 2,
          DeviceKind.generic => 1,
          DeviceKind.synthetic => 16,
          null => 16,
        };
  }

  List<String> get channelLabels {
    final profile = _activeProfile;
    if (profile != null) {
      return profile.enabledStreams
          .expand((stream) => stream.channelLabels)
          .toList(growable: false);
    }
    return switch (_lastConnectedDevice?.kind) {
      DeviceKind.epidome => const [
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
      DeviceKind.orbit => const ['AF7', 'AF8', 'PPG'],
      DeviceKind.synthetic => const [
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
      DeviceKind.generic => const ['Ch 1'],
      null => const [
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
    };
  }

  /// Returns configured labels without discarding them when the live decoder
  /// exposes more channels than the saved profile.
  List<String> displayChannelLabels(int liveChannelCount) {
    final configured = channelLabels;
    return List<String>.generate(liveChannelCount, (index) {
      if (index < configured.length && configured[index].trim().isNotEmpty) {
        return configured[index].trim();
      }
      return 'Ch ${index + 1}';
    }, growable: false);
  }

  List<SignalType> displayChannelTypes(int liveChannelCount) {
    final configured =
        _activeProfile?.enabledStreams
            .expand((stream) => stream.channelTypes)
            .toList(growable: false) ??
        const <SignalType>[];
    final labels = displayChannelLabels(liveChannelCount);
    return List<SignalType>.generate(liveChannelCount, (index) {
      if (index < configured.length) return configured[index];
      return SignalStreamProfile.inferChannelType(labels[index]);
    }, growable: false);
  }

  /// Uses saved channel configuration only when it belongs to the active
  /// device shape. This prevents a 16-channel xAMP configuration from naming
  /// ORBIT's third channel as an EEG electrode instead of PPG.
  List<String> recordingChannelLabels(List<String>? configured) {
    if (_lastConnectedDevice?.kind == DeviceKind.orbit &&
        (_settings?.combineCompatibleStreams ?? true)) {
      return List<String>.of(channelLabels);
    }
    if (configured != null && configured.length == channelCount) {
      return List<String>.of(configured);
    }
    final primary = primaryRecordingStream;
    return primary == null
        ? List<String>.of(channelLabels.take(channelCount))
        : List<String>.of(primary.channelLabels);
  }

  List<bool> recordingEnabledChannels(List<bool>? configured) {
    final profileEnabled = _activeProfile?.enabledStreams
        .expand((stream) => stream.channelEnabled)
        .toList(growable: false);
    if (profileEnabled != null && profileEnabled.length == channelCount) {
      return profileEnabled;
    }
    if (_lastConnectedDevice?.kind == DeviceKind.orbit &&
        (_settings?.combineCompatibleStreams ?? true)) {
      final result = List<bool>.filled(channelCount, true);
      if (configured != null) {
        for (var i = 0; i < configured.length && i < 2; i++) {
          result[i] = configured[i];
        }
      }
      return result;
    }
    if (configured != null && configured.length == channelCount) {
      return List<bool>.of(configured);
    }
    return List<bool>.filled(channelCount, true);
  }

  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;

    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> scan({bool autoConnect = true}) async {
    if (_currentState == AcquisitionState.connecting ||
        _currentState == AcquisitionState.streaming) {
      debugPrint(
        '[AcquisitionService] Already connecting or streaming! Skipping scan request to preserve connection stability.',
      );
      return;
    }
    await requestPermissions();
    _setState(AcquisitionState.scanning);
    _seenDevices.removeWhere((device) => device.kind != DeviceKind.synthetic);
    _publishDevices();

    await _bleScanSub?.cancel();
    _bleScanSub = ble.FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final name = result.device.platformName.isNotEmpty
            ? result.device.platformName
            : result.advertisementData.advName;
        final profile = _matchingProfile(
          name,
          result.device.remoteId.toString(),
          ConnectionTransport.bluetoothLe,
        );
        if (profile == null) continue;
        final device = EegDevice(
          name: name.isEmpty ? 'Unknown BLE device' : name,
          id: result.device.remoteId.toString(),
          kind: _kindForProfile(profile),
          isBle: true,
          profileId: profile.id,
        );
        _addDevice(device);
        if (autoConnect && profile.autoConnect) {
          debugPrint(
            '[AcquisitionService] Found BLE target device $name (${device.id}). Auto-connecting!',
          );
          unawaited(connect(device));
          return;
        }
      }
    });

    await _classicScanSub?.cancel();
    if (Platform.isAndroid) {
      _classicScanSub = classic.FlutterBluetoothSerial.instance
          .startDiscovery()
          .listen((result) {
            final name = result.device.name ?? 'Unknown classic device';
            final profile = _matchingProfile(
              name,
              result.device.address,
              ConnectionTransport.bluetoothClassic,
            );
            if (profile == null) return;
            final device = EegDevice(
              name: name,
              id: result.device.address,
              kind: _kindForProfile(profile),
              isBle: false,
              profileId: profile.id,
            );
            _addDevice(device);
          });
    } else {
      _classicScanSub = null;
    }

    await ble.FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 20),
      continuousUpdates: true,
      androidCheckLocationServices: false,
    );

    Future<void>.delayed(const Duration(seconds: 21), () async {
      if (_currentState == AcquisitionState.scanning) {
        await stopScan();
        _setState(AcquisitionState.disconnected);
      }
    });
  }

  Future<void> stopScan() async {
    await _classicScanSub?.cancel();
    _classicScanSub = null;
    await _bleScanSub?.cancel();
    _bleScanSub = null;
    if (ble.FlutterBluePlus.isScanningNow) {
      await ble.FlutterBluePlus.stopScan();
    }
  }

  Future<bool> connect(
    EegDevice device, {
    bool reconnectAttempt = false,
  }) async {
    if (isStreamReady && _lastConnectedDevice == device) {
      debugPrint(
        '[AcquisitionService] ${device.name} is already streaming valid samples.',
      );
      return true;
    }
    if (_currentState == AcquisitionState.connecting) {
      debugPrint(
        '[AcquisitionService] A connection is already in progress; ignoring '
        'duplicate request for ${device.name}.',
      );
      return false;
    }
    if (!reconnectAttempt) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _reconnectAttempts = 0;
      _autoReconnectEnabled = true;
      _hasEverStreamed = false;
    }
    await stopScan();
    await _cleanupSockets();

    final targetDevice = device;

    if (Platform.isAndroid && targetDevice.isBle) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    _setState(AcquisitionState.connecting);
    _deliveredSampleCount = 0;
    _rateWindowStarted = null;
    _rateWindowSamples = 0;
    _rateWindowNotifications = 0;
    _rateWindowBytes = 0;
    _deliveredSampleRate = null;
    _resetXampSaturation();
    _connectionCancelled = false;
    _firstSampleCompleter = Completer<void>();

    try {
      _lastConnectedDevice = targetDevice;
      _autoReconnectEnabled = true;
      if (targetDevice.kind == DeviceKind.synthetic) {
        _startSynthetic();
      } else if (targetDevice.isBle) {
        await _connectBle(targetDevice);
      } else if (!Platform.isAndroid) {
        throw UnsupportedError(
          'Bluetooth Classic device profiles are supported on Android only. '
          'Use a BLE or LSL device profile on desktop.',
        );
      } else {
        await _connectClassic(targetDevice);
      }
      await _firstSampleCompleter!.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => throw TimeoutException(
          '${targetDevice.name} connected but sent no valid signal frames.',
        ),
      );
      if (_connectionCancelled) {
        throw StateError('Connection cancelled by user.');
      }
      _startWatchdog();
      _alertService?.stopBeeping();
      return isStreamReady;
    } catch (e) {
      debugPrint('[AcquisitionService] Connect error for ${device.name}: $e');
      await _cleanupStaleConnection();
      _setState(AcquisitionState.disconnected);
      if (!reconnectAttempt) {
        _scheduleReconnect();
      }
      return false;
    }
  }

  void _startWatchdog() {
    _stopWatchdog();
    _lastSampleTime = DateTime.now().add(
      Duration(seconds: disconnectionTimeoutSeconds),
    );
    _watchdogTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_currentState == AcquisitionState.streaming &&
          _lastConnectedDevice?.kind != DeviceKind.synthetic) {
        final elapsed = DateTime.now().difference(_lastSampleTime).inSeconds;
        if (elapsed >= disconnectionTimeoutSeconds) {
          debugPrint(
            '[AcquisitionService] Watchdog timeout: No EEG samples for ${elapsed}s! Triggering reconnect.',
          );
          _handleUnexpectedDisconnect();
        }
      }
    });
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
  }

  Future<void> disconnect() async {
    _autoReconnectEnabled = false;
    _connectionCancelled = true;
    if (!(_firstSampleCompleter?.isCompleted ?? true)) {
      _firstSampleCompleter!.complete();
    }
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopWatchdog();
    _alertService?.stopBeeping();
    await _cleanupSockets();
    _lastConnectedDevice = null;
    _deliveredSampleCount = 0;
    _firstSampleCompleter = null;
    _hasEverStreamed = false;
    _handlingUnexpectedDisconnect = false;
  }

  Future<void> _cleanupSockets() async {
    _syntheticTimer?.cancel();
    _syntheticTimer = null;
    await _classicInputSub?.cancel();
    _classicInputSub = null;
    await _classicConnection?.close();
    _classicConnection = null;
    await _bleNotifySub?.cancel();
    _bleNotifySub = null;
    await _bleConnectionStateSub?.cancel();
    _bleConnectionStateSub = null;
    try {
      await _bleDevice?.disconnect();
    } catch (_) {}
    _bleDevice = null;
    _classicBuffer.clear();
    _bleBuffer.clear();
    _orbitTextBuffer = '';
    _orbitAsciiSampleIndex = 0;
    _orbitEegClock.reset();
    _orbitPpgClock.reset();
    _orbitDecoder.reset();
    _resetXampSaturation();
    if (_currentState != AcquisitionState.disconnected) {
      _setState(AcquisitionState.disconnected);
    }
  }

  @override
  void dispose() {
    unawaited(disconnect());
    _state.close();
    _samples.close();
    _streamSamples.close();
    _devices.close();
    _maxRetriesReachedController.close();
    super.dispose();
  }

  void _handleUnexpectedDisconnect() {
    if (!_autoReconnectEnabled || _lastConnectedDevice == null) {
      return;
    }
    if (_handlingUnexpectedDisconnect ||
        _reconnectInProgress ||
        (_reconnectTimer?.isActive ?? false)) {
      _stopWatchdog();
      debugPrint(
        '[AcquisitionService] Recovery is already active; ignoring duplicate '
        'disconnect/watchdog event.',
      );
      return;
    }
    _handlingUnexpectedDisconnect = true;
    debugPrint(
      '[AcquisitionService] Unexpected disconnect / watchdog timeout detected!',
    );
    _stopWatchdog();
    _setState(AcquisitionState.disconnected);
    // A failed initial connection must not alarm the participant. The warning
    // is reserved for loss of a stream that previously delivered valid EEG.
    if (reconnectBeepEnabled && _hasEverStreamed) {
      _alertService?.startBeeping();
    }
    _cleanupStaleConnection().then((_) {
      _handlingUnexpectedDisconnect = false;
      _scheduleReconnect();
    });
  }

  Future<void> _cleanupStaleConnection() async {
    await _classicInputSub?.cancel();
    _classicInputSub = null;
    await _bleNotifySub?.cancel();
    _bleNotifySub = null;
    await _bleConnectionStateSub?.cancel();
    _bleConnectionStateSub = null;
    _classicBuffer.clear();
    _bleBuffer.clear();
    _orbitTextBuffer = '';
    _orbitEegClock.reset();
    _orbitPpgClock.reset();
    _orbitDecoder.reset();
    _resetXampSaturation();
    try {
      _classicConnection?.dispose();
    } catch (_) {}
    _classicConnection = null;
    try {
      await _bleDevice?.disconnect();
    } catch (_) {}
    _bleDevice = null;
  }

  void _scheduleReconnect() {
    if (!_autoReconnectEnabled ||
        _lastConnectedDevice == null ||
        _reconnectInProgress ||
        (_reconnectTimer?.isActive ?? false)) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: reconnectIntervalSec), () async {
      _reconnectTimer = null;
      if (_lastConnectedDevice == null || !_autoReconnectEnabled) {
        _alertService?.stopBeeping();
        return;
      }
      _reconnectAttempts++;
      if (reconnectMaxAttempts > 0 &&
          _reconnectAttempts > reconnectMaxAttempts) {
        _stopReconnectTimer();
        _maxRetriesReachedController.add(null);
        return;
      }

      debugPrint(
        '[AcquisitionService] Auto-reconnect attempt $_reconnectAttempts'
        '${reconnectMaxAttempts > 0 ? '/$reconnectMaxAttempts' : ''}: '
        'connecting to ${_lastConnectedDevice!.name}',
      );

      _reconnectInProgress = true;
      final target = _lastConnectedDevice!;
      final success = await connect(target, reconnectAttempt: true);
      _reconnectInProgress = false;
      if (success) {
        debugPrint('[AcquisitionService] Auto-reconnect successful!');
        _reconnectAttempts = 0;
        _alertService?.stopBeeping();
      } else {
        debugPrint('[AcquisitionService] Auto-reconnect did not yield EEG.');
        _scheduleReconnect();
      }
    });
  }

  void _stopReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void addSyntheticDevice() {
    _addDevice(
      const EegDevice(
        name: 'Synthetic frontal EEG',
        id: 'synthetic',
        kind: DeviceKind.synthetic,
        isBle: false,
        profileId: 'synthetic',
      ),
    );
  }

  Future<void> _connectClassic(EegDevice device) async {
    try {
      final bondState = await classic.FlutterBluetoothSerial.instance
          .getBondStateForAddress(device.id);
      debugPrint(
        '[AcquisitionService] Current bond state for ${device.id}: $bondState',
      );
      if (!bondState.isBonded) {
        debugPrint(
          '[AcquisitionService] Device is not bonded. Triggering bonding first...',
        );
        final bonded = await classic.FlutterBluetoothSerial.instance
            .bondDeviceAtAddress(device.id);
        debugPrint('[AcquisitionService] Bonding result: $bonded');
        await Future.delayed(const Duration(milliseconds: 1000));
      }
    } catch (e) {
      debugPrint('[AcquisitionService] Bond state check/bonding failed: $e');
    }

    int retries = 3;
    while (retries > 0) {
      try {
        _classicConnection = await classic.BluetoothConnection.toAddress(
          device.id,
        );
        break;
      } catch (e) {
        retries--;
        debugPrint(
          '[AcquisitionService] Classic connect failed: $e. Retries left: $retries',
        );
        if (retries == 0) rethrow;
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    _classicInputSub = _classicConnection!.input?.listen(
      (data) {
        _parseDeviceBytes(device, Uint8List.fromList(data));
      },
      onDone: () => _handleUnexpectedDisconnect(),
      onError: (e) => _handleUnexpectedDisconnect(),
    );
  }

  Future<void> _connectBle(EegDevice device) async {
    _bleDevice = ble.BluetoothDevice.fromId(device.id);
    int retries = 5;
    while (retries > 0) {
      try {
        await _bleDevice!.connect(
          license: ble.License.nonprofit,
          timeout: const Duration(seconds: 12),
          autoConnect: false,
        );
        break;
      } catch (e) {
        retries--;
        debugPrint(
          '[AcquisitionService] BLE connect failed: $e. Retries left: $retries',
        );
        if (retries == 0) rethrow;
        try {
          await _bleDevice!.disconnect();
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 2000));
      }
    }
    await _bleConnectionStateSub?.cancel();
    _bleConnectionStateSub = _bleDevice!.connectionState.listen((state) {
      if (state == ble.BluetoothConnectionState.disconnected &&
          _autoReconnectEnabled) {
        debugPrint('[BLE Bluetooth] connection state is disconnected');
        _handleUnexpectedDisconnect();
      }
    });
    if (Platform.isAndroid) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    if (!_bleDevice!.isConnected) {
      debugPrint(
        '[BLE Bluetooth] Device dropped right after connect! Retrying connect...',
      );
      try {
        await _bleDevice!.connect(
          license: ble.License.nonprofit,
          timeout: const Duration(seconds: 8),
          autoConnect: false,
        );
      } catch (_) {}
      if (Platform.isAndroid) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
    try {
      await _bleDevice!.requestMtu(247, predelay: 0);
    } catch (error) {
      debugPrint('[BLE Bluetooth] MTU request skipped/failed: $error');
    }
    List<ble.BluetoothService> services = [];
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        if (!_bleDevice!.isConnected) {
          debugPrint(
            '[BLE GATT] Device disconnected before discoverServices! Re-connecting...',
          );
          try {
            await _bleDevice!.connect(
              license: ble.License.nonprofit,
              timeout: const Duration(seconds: 8),
              autoConnect: false,
            );
          } catch (_) {}
          if (Platform.isAndroid) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        }
        services = await _bleDevice!.discoverServices();
        if (services.isNotEmpty) break;
      } catch (e) {
        debugPrint('[BLE GATT] discoverServices attempt $attempt failed: $e');
      }
      await Future.delayed(const Duration(milliseconds: 600));
    }
    final characteristics = services
        .expand((service) => service.characteristics)
        .toList();
    for (final characteristic in characteristics) {
      debugPrint(
        '[BLE GATT] ${characteristic.serviceUuid}/'
        '${characteristic.characteristicUuid} '
        'write=${characteristic.properties.write || characteristic.properties.writeWithoutResponse} '
        'notify=${characteristic.properties.notify || characteristic.properties.indicate}',
      );
    }
    final pair = _protocolFor(device) == DeviceProtocol.xampBinary
        ? _selectEpiDomeCharacteristics(characteristics)
        : _selectOrbitCharacteristics(characteristics);
    final notify = pair?.notify;
    final write = pair?.write;
    if (notify == null) {
      throw StateError('No BLE notify characteristic found for ${device.name}');
    }
    await _bleNotifySub?.cancel();
    _bleNotifySub = notify.onValueReceived.listen((data) {
      _trackTransportChunk(data.length);
      _parseDeviceBytes(device, Uint8List.fromList(data), bleSource: true);
    });
    await notify.setNotifyValue(true);
    if (write != null) {
      final configuredCommand = _profileFor(device)?.startCommand ?? '';
      final command = configuredCommand.isNotEmpty
          ? utf8.encode(configuredCommand)
          : _protocolFor(device) == DeviceProtocol.xampBinary
          ? [0x72, 0x78, 0x73, 0x37]
          : utf8.encode('9');
      final withoutResponse =
          write.properties.writeWithoutResponse && !write.properties.write;
      await write.write(command, withoutResponse: withoutResponse);
    }
  }

  void _parseDeviceBytes(
    EegDevice device,
    Uint8List data, {
    bool bleSource = false,
  }) {
    switch (_protocolFor(device)) {
      case DeviceProtocol.xampBinary:
        _parseEpiDomeBytes(data, bleSource: bleSource);
      case DeviceProtocol.orbitJson:
        if (bleSource) {
          _parseOrbitBleBytes(data);
        } else {
          _parseAsciiOrbit(data, bleSource: false);
        }
      case DeviceProtocol.delimitedText:
        _parseDelimitedText(data, bleSource: bleSource);
      case DeviceProtocol.synthetic:
      case DeviceProtocol.lsl:
        break;
    }
  }

  void _parseEpiDomeBytes(Uint8List data, {bool bleSource = false}) {
    final buffer = bleSource ? _bleBuffer : _classicBuffer;
    buffer.addAll(data);
    while (buffer.length >= _epidomeFrameHeaderLength) {
      final start = _findEpiDomeFrameHeader(buffer);
      if (start < 0) {
        final keepTrailing = buffer.reversed
            .takeWhile((byte) => byte == _epidomeFrameHeader)
            .length
            .clamp(0, _epidomeFrameHeaderLength - 1);
        final trailing = keepTrailing == 0
            ? const <int>[]
            : buffer.sublist(buffer.length - keepTrailing);
        buffer.clear();
        buffer.addAll(trailing);
        return;
      }
      if (start > 0) {
        buffer.removeRange(0, start);
      }
      if (buffer.length < _epidomeFrameLength) return;
      final channels = List<double>.filled(_epidomeChannelCount, 0.0);
      for (var i = 0; i < _epidomeChannelCount; i++) {
        final offset = _epidomeFrameHeaderLength + i * 3;
        final raw = Ads1299Scaling.signed24(
          buffer[offset],
          buffer[offset + 1],
          buffer[offset + 2],
        );
        final atRail = Ads1299Scaling.isAtRail(raw);
        _xampRailRuns[i] = atRail
            ? min(250, _xampRailRuns[i] + 1)
            : max(0, _xampRailRuns[i] - 1);
        if (_xampRailRuns[i] >= 25) {
          _xampSaturatedChannels.add(i);
        } else if (_xampRailRuns[i] == 0) {
          _xampSaturatedChannels.remove(i);
        }
        channels[i] = Ads1299Scaling.xampMicrovolts(raw);
      }
      buffer.removeRange(0, _epidomeFrameLength);
      _markSampleDelivered();
      _samples.add(
        EegSample(
          channels: channels,
          sampleRate: 250,
          timestamp: DateTime.now(),
          source: 'EpiDome/xAMP-L10',
        ),
      );
    }
  }

  int _findEpiDomeFrameHeader(List<int> buffer) {
    for (var i = 0; i <= buffer.length - _epidomeFrameHeaderLength; i++) {
      if (buffer[i] == _epidomeFrameHeader &&
          buffer[i + 1] == _epidomeFrameHeader &&
          buffer[i + 2] == _epidomeFrameHeader) {
        return i;
      }
    }
    return -1;
  }

  void _resetXampSaturation() {
    for (var i = 0; i < _xampRailRuns.length; i++) {
      _xampRailRuns[i] = 0;
    }
    _xampSaturatedChannels.clear();
  }

  void _parseAsciiOrbit(Uint8List data, {bool bleSource = false}) {
    final buffer = bleSource ? _bleBuffer : _classicBuffer;
    buffer.addAll(data);
    while (buffer.contains(10)) {
      final end = buffer.indexOf(10);
      final line = String.fromCharCodes(buffer.sublist(0, end)).trim();
      buffer.removeRange(0, end + 1);
      final values = line
          .split(RegExp(r'[\s,;]+'))
          .map(double.tryParse)
          .whereType<double>()
          .toList(growable: false);
      if (values.isNotEmpty) {
        final chs = values.take(3).toList();
        while (chs.length < 3) {
          chs.add(0.0);
        }
        chs[2] = _orbitDecoder.filterPpg(chs[2], sampleRate: 250);

        _markSampleDelivered();
        _samples.add(
          EegSample(
            channels: chs,
            sampleRate: 250,
            timestamp: DateTime.now(),
            source: 'Orbit',
          ),
        );
        final ppgStream = _activeProfile?.enabledStreams
            .where((stream) => stream.signalType == SignalType.ppg)
            .firstOrNull;
        if (ppgStream != null && _orbitAsciiSampleIndex % 4 == 0) {
          _streamSamples.add(
            SignalStreamSample(
              deviceProfileId: _activeProfile!.id,
              streamId: ppgStream.id,
              signalType: SignalType.ppg,
              channels: [chs[2]],
              channelLabels: List<String>.of(ppgStream.channelLabels),
              channelTypes: List<SignalType>.of(ppgStream.channelTypes),
              sampleRate: ppgStream.sampleRate,
              timestamp: DateTime.now(),
              unit: ppgStream.unit,
              physicalMinimum: ppgStream.physicalMinimum,
              physicalMaximum: ppgStream.physicalMaximum,
            ),
          );
        }
        _orbitAsciiSampleIndex++;
      }
    }
  }

  void _parseOrbitBleBytes(List<int> data) {
    _orbitTextBuffer += utf8.decode(data, allowMalformed: true);
    final decodedPackets = <OrbitDecodedPacket>[];
    while (true) {
      final start = _orbitTextBuffer.indexOf('{');
      if (start < 0) {
        if (_orbitTextBuffer.length > 500) _orbitTextBuffer = '';
        break;
      }
      final end = _orbitTextBuffer.indexOf('}', start);
      if (end < 0) break;
      final packet = _orbitTextBuffer.substring(start, end + 1);
      _orbitTextBuffer = _orbitTextBuffer.substring(end + 1);
      try {
        decodedPackets.add(_orbitDecoder.decodeDetailed(packet));
      } catch (error) {
        debugPrint('[Orbit parse] $error');
      }
    }
    if (decodedPackets.isEmpty) return;

    final arrival = DateTime.now();
    final eegSamples = decodedPackets
        .expand((packet) => packet.displaySamples)
        .toList(growable: false);
    var eegTimestamp = _orbitEegClock.firstTimestampForBatch(
      packetArrival: arrival,
      sampleCount: eegSamples.length,
      sampleRate: 250,
    );
    const eegPeriod = Duration(microseconds: 4000);
    for (final channels in eegSamples) {
      _markSampleDelivered();
      _samples.add(
        EegSample(
          channels: channels,
          sampleRate: 250,
          timestamp: eegTimestamp,
          source: 'Orbit',
        ),
      );
      eegTimestamp = eegTimestamp.add(eegPeriod);
    }

    final ppgStream = _activeProfile?.enabledStreams
        .where((stream) => stream.signalType == SignalType.ppg)
        .firstOrNull;
    if (ppgStream == null) return;
    final ppgSamples = decodedPackets
        .expand((packet) => packet.ppgSamples)
        .toList(growable: false);
    final ppgPeriod = Duration(
      microseconds: (1000000 / ppgStream.sampleRate).round(),
    );
    var ppgTimestamp = _orbitPpgClock.firstTimestampForBatch(
      packetArrival: arrival,
      sampleCount: ppgSamples.length,
      sampleRate: ppgStream.sampleRate,
    );
    for (final value in ppgSamples) {
      _streamSamples.add(
        SignalStreamSample(
          deviceProfileId: _activeProfile!.id,
          streamId: ppgStream.id,
          signalType: SignalType.ppg,
          channels: [value],
          channelLabels: List<String>.of(ppgStream.channelLabels),
          channelTypes: List<SignalType>.of(ppgStream.channelTypes),
          sampleRate: ppgStream.sampleRate,
          timestamp: ppgTimestamp,
          unit: ppgStream.unit,
          physicalMinimum: ppgStream.physicalMinimum,
          physicalMaximum: ppgStream.physicalMaximum,
        ),
      );
      ppgTimestamp = ppgTimestamp.add(ppgPeriod);
    }
  }

  void _parseDelimitedText(Uint8List data, {bool bleSource = false}) {
    final buffer = bleSource ? _bleBuffer : _classicBuffer;
    buffer.addAll(data);
    final profile = _activeProfile;
    final streams = profile?.enabledStreams.toList() ?? const [];
    final delimiter = profile?.delimiter ?? ',';
    while (buffer.contains(10)) {
      final end = buffer.indexOf(10);
      final line = String.fromCharCodes(buffer.sublist(0, end)).trim();
      buffer.removeRange(0, end + 1);
      final separator = delimiter.trim().isEmpty
          ? RegExp(r'[\s,;]+')
          : RegExp('${RegExp.escape(delimiter)}|\\s+');
      final values = line
          .split(separator)
          .map(double.tryParse)
          .whereType<double>()
          .toList(growable: false);
      var offset = 0;
      for (final stream in streams) {
        if (offset + stream.channelCount > values.length) break;
        final channels = values.sublist(offset, offset + stream.channelCount);
        offset += stream.channelCount;
        _streamSamples.add(
          SignalStreamSample(
            deviceProfileId: profile!.id,
            streamId: stream.id,
            signalType: stream.signalType,
            channels: channels,
            channelLabels: List<String>.of(stream.channelLabels),
            channelTypes: List<SignalType>.of(stream.channelTypes),
            sampleRate: stream.sampleRate,
            timestamp: DateTime.now(),
            unit: stream.unit,
            physicalMinimum: stream.physicalMinimum,
            physicalMaximum: stream.physicalMaximum,
          ),
        );
        if (stream == primaryRecordingStream) {
          _markSampleDelivered();
          _samples.add(
            EegSample(
              channels: channels,
              sampleRate: stream.sampleRate,
              timestamp: DateTime.now(),
              source: profile.name,
            ),
          );
        }
      }
    }
  }

  ({ble.BluetoothCharacteristic? write, ble.BluetoothCharacteristic notify})?
  _selectEpiDomeCharacteristics(
    List<ble.BluetoothCharacteristic> characteristics,
  ) {
    bool canWrite(ble.BluetoothCharacteristic c) =>
        c.properties.write || c.properties.writeWithoutResponse;
    bool canNotify(ble.BluetoothCharacteristic c) =>
        c.properties.notify || c.properties.indicate;

    ble.BluetoothCharacteristic? find(String suffix) {
      final target = suffix.toLowerCase();
      for (final characteristic in characteristics) {
        final uuid = characteristic.characteristicUuid.toString().toLowerCase();
        if (uuid == target || uuid.endsWith('-$target')) {
          return characteristic;
        }
      }
      return null;
    }

    final nordicWrite = find(_nordicUartRxUuid);
    final nordicNotify = find(_nordicUartTxUuid);
    if (nordicWrite != null &&
        nordicNotify != null &&
        canWrite(nordicWrite) &&
        canNotify(nordicNotify)) {
      return (write: nordicWrite, notify: nordicNotify);
    }

    final hm10Data = find(_hm10DataUuid);
    if (hm10Data != null && canWrite(hm10Data) && canNotify(hm10Data)) {
      return (write: hm10Data, notify: hm10Data);
    }

    final write = find(_tiDataStreamWriteUuid);
    final notify = find(_tiDataStreamNotifyUuid);
    if (write != null &&
        notify != null &&
        canWrite(write) &&
        canNotify(notify)) {
      return (write: write, notify: notify);
    }

    for (final serviceUuid in [
      _nordicUartServiceUuid,
      _hm10ServiceUuid,
      _tiDataStreamServiceUuid,
    ]) {
      final serviceChars = characteristics.where((c) {
        final uuid = c.serviceUuid.toString().toLowerCase();
        return uuid == serviceUuid || uuid.endsWith('-$serviceUuid');
      }).toList();
      if (serviceChars.isEmpty) continue;
      final serviceWrite = serviceChars.where(canWrite).firstOrNull;
      final serviceNotify = serviceChars.where(canNotify).firstOrNull;
      if (serviceWrite != null && serviceNotify != null) {
        return (write: serviceWrite, notify: serviceNotify);
      }
    }

    return _selectNonStandardPair(characteristics);
  }

  ({ble.BluetoothCharacteristic? write, ble.BluetoothCharacteristic notify})?
  _selectOrbitCharacteristics(
    List<ble.BluetoothCharacteristic> characteristics,
  ) {
    return _selectNonStandardPair(characteristics);
  }

  ({ble.BluetoothCharacteristic? write, ble.BluetoothCharacteristic notify})?
  _selectNonStandardPair(List<ble.BluetoothCharacteristic> characteristics) {
    final byService = <String, List<ble.BluetoothCharacteristic>>{};
    for (final characteristic in characteristics) {
      final service = characteristic.serviceUuid.toString().toLowerCase();
      if (service.contains('00001800-') ||
          service.contains('00001801-') ||
          service.contains('0000180f-')) {
        continue;
      }
      byService.putIfAbsent(service, () => []).add(characteristic);
    }
    for (final entries in byService.values) {
      final write = entries
          .where(
            (entry) =>
                entry.properties.write || entry.properties.writeWithoutResponse,
          )
          .firstOrNull;
      final notify = entries
          .where(
            (entry) => entry.properties.notify || entry.properties.indicate,
          )
          .firstOrNull;
      if (write != null && notify != null) {
        return (write: write, notify: notify);
      }
    }
    ble.BluetoothCharacteristic? fallbackNotify;
    ble.BluetoothCharacteristic? fallbackWrite;
    for (final entries in byService.values) {
      for (final c in entries) {
        if (fallbackNotify == null &&
            (c.properties.notify || c.properties.indicate)) {
          fallbackNotify = c;
        }
        if (fallbackWrite == null &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          fallbackWrite = c;
        }
      }
    }
    if (fallbackNotify != null) {
      return (write: fallbackWrite, notify: fallbackNotify);
    }
    return null;
  }

  void _markSampleDelivered() {
    // A notification already queued by the platform can arrive while a manual
    // disconnect is cancelling subscriptions. It must never resurrect the
    // viewer or mark that cancelled connection as streaming.
    if (_connectionCancelled) return;
    _lastSampleTime = DateTime.now();
    _deliveredSampleCount++;
    _rateWindowSamples++;
    _reportTransportRateIfDue();
    final firstSample = _deliveredSampleCount == 1;
    if (!(_firstSampleCompleter?.isCompleted ?? true)) {
      _firstSampleCompleter!.complete();
    }
    if (firstSample) {
      _hasEverStreamed = true;
      _stopReconnectTimer();
      _alertService?.stopBeeping();
      _setState(AcquisitionState.streaming);
      debugPrint(
        '[AcquisitionService] Valid samples received from '
        '${_lastConnectedDevice?.name ?? 'device'}.',
      );
    }
  }

  void _trackTransportChunk(int byteCount) {
    _rateWindowStarted ??= DateTime.now();
    _rateWindowNotifications++;
    _rateWindowBytes += byteCount;
  }

  void _reportTransportRateIfDue() {
    final started = _rateWindowStarted;
    if (started == null) return;
    final elapsedSeconds =
        DateTime.now().difference(started).inMicroseconds / 1000000;
    if (elapsedSeconds < 5) return;
    _deliveredSampleRate = _rateWindowSamples / elapsedSeconds;
    if (kDebugMode) {
      debugPrint(
        '[Acquisition rate] ${_lastConnectedDevice?.name ?? 'device'} '
        '${_deliveredSampleRate!.toStringAsFixed(1)} samples/s, '
        '${(_rateWindowNotifications / elapsedSeconds).toStringAsFixed(1)} '
        'notifications/s, '
        '${(_rateWindowBytes / elapsedSeconds).toStringAsFixed(0)} bytes/s.',
      );
    }
    _rateWindowStarted = DateTime.now();
    _rateWindowSamples = 0;
    _rateWindowNotifications = 0;
    _rateWindowBytes = 0;
    notifyListeners();
  }

  void _startSynthetic() {
    _syntheticTimer = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final stageCycle = (_syntheticT / 60).floor() % 4;
      final baseFreq = switch (stageCycle) {
        0 => 10.0,
        1 => 6.0,
        2 => 2.0,
        _ => 14.0,
      };
      final amp = stageCycle == 2 ? 85.0 : 35.0;
      final channels = List<double>.generate(16, (ch) {
        final chPhase = ch * 0.4;
        final chAmp = (amp * (1.0 - ch * 0.03)).clamp(10.0, 100.0);
        return chAmp * sin(2 * pi * baseFreq * _syntheticT + chPhase) +
            _random.nextDouble() * 10.0 -
            5.0;
      });
      _markSampleDelivered();
      _samples.add(
        EegSample(
          channels: channels,
          sampleRate: 250,
          timestamp: DateTime.now(),
          source: 'Synthetic',
        ),
      );
      _syntheticT += 0.004;
    });
  }

  DeviceProfile? _profileFor(EegDevice device) {
    final id = device.profileId;
    return id == null ? null : _settings?.profileById(id);
  }

  DeviceProtocol _protocolFor(EegDevice device) =>
      _profileFor(device)?.protocol ??
      switch (device.kind) {
        DeviceKind.epidome => DeviceProtocol.xampBinary,
        DeviceKind.orbit => DeviceProtocol.orbitJson,
        DeviceKind.generic => DeviceProtocol.delimitedText,
        DeviceKind.synthetic => DeviceProtocol.synthetic,
      };

  DeviceKind _kindForProfile(DeviceProfile profile) =>
      switch (profile.protocol) {
        DeviceProtocol.xampBinary => DeviceKind.epidome,
        DeviceProtocol.orbitJson => DeviceKind.orbit,
        DeviceProtocol.synthetic => DeviceKind.synthetic,
        DeviceProtocol.delimitedText ||
        DeviceProtocol.lsl => DeviceKind.generic,
      };

  DeviceProfile? _matchingProfile(
    String name,
    String address,
    ConnectionTransport transport,
  ) {
    final upperName = name.toUpperCase();
    final upperAddress = address.toUpperCase();
    final profiles = _settings?.deviceProfiles ?? defaultDeviceProfiles();
    for (final profile in profiles) {
      if (!profile.enabled || profile.transport != transport) continue;
      final namePattern = profile.advertisedNamePattern.trim().toUpperCase();
      final addressPattern = profile.addressPattern.trim().toUpperCase();
      final nameMatches =
          namePattern.isNotEmpty &&
          (upperName.contains(namePattern) ||
              upperName.startsWith(namePattern));
      final addressMatches =
          addressPattern.isNotEmpty && upperAddress.contains(addressPattern);
      if (nameMatches || addressMatches) return profile;
    }
    return null;
  }

  void _addDevice(EegDevice device) {
    if (device.kind != DeviceKind.synthetic && device.profileId == null) {
      return;
    }
    final normalized = device;

    final existing = _seenDevices.indexWhere(
      (entry) => entry.id == normalized.id,
    );
    if (existing >= 0) {
      _seenDevices[existing] = normalized;
    } else {
      _seenDevices.add(normalized);
      if (normalized.name != 'Unknown BLE device' &&
          normalized.name != 'Unknown classic device') {
        debugPrint(
          '[Bluetooth scan] Added device ${normalized.name} (${normalized.id})',
        );
      }
    }
    _publishDevices();
  }

  void _publishDevices() {
    _devices.add(List.unmodifiable(_seenDevices));
    notifyListeners();
  }

  void _setState(AcquisitionState value) {
    if (_currentState == value) return;
    _currentState = value;
    _state.add(value);
    debugPrint('[Acquisition] $value');
    notifyListeners();
  }
}
