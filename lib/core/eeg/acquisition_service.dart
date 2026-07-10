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
import '../services/alert_service.dart';
import '../services/settings_service.dart';

enum DeviceKind { orbit, epidome, synthetic }

enum AcquisitionState { disconnected, scanning, connecting, streaming }

class EegDevice {
  const EegDevice({
    required this.name,
    required this.id,
    required this.kind,
    required this.isBle,
  });

  final String name;
  final String id;
  final DeviceKind kind;
  final bool isBle;

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
  static const double _ads1299UvPerCount = -0.0224;

  final _state = StreamController<AcquisitionState>.broadcast();
  final _samples = StreamController<EegSample>.broadcast();
  final _devices = StreamController<List<EegDevice>>.broadcast();

  StreamSubscription<ble.BluetoothConnectionState>? _bleConnectionStateSub;

  AcquisitionState _currentState = AcquisitionState.disconnected;
  final List<EegDevice> _seenDevices = [];
  final List<int> _classicBuffer = [];
  final List<int> _bleBuffer = [];
  String _orbitTextBuffer = '';
  final _random = Random();
  double _ppgX1 = 0.0;
  double _ppgY1 = 0.0;
  double _ppgSmooth = 0.0;

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
  AlertService? _alertService;

  void updateAlertService(AlertService? alertService) {
    _alertService = alertService;
  }

  void updateSettings(SettingsService? settings) {
    if (settings != null) {
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
  Stream<List<EegDevice>> get devices => _devices.stream;
  List<EegDevice> get discoveredDevices => List.unmodifiable(_seenDevices);
  AcquisitionState get currentState => _currentState;

  double get sampleRate => switch (_lastConnectedDevice?.kind) {
    DeviceKind.epidome => 250.0,
    DeviceKind.orbit => 250.0,
    DeviceKind.synthetic => 250.0,
    null => 250.0,
  };

  int get channelCount => switch (_lastConnectedDevice?.kind) {
    DeviceKind.epidome => 16,
    DeviceKind.orbit => 3,
    DeviceKind.synthetic => 16,
    null => 16,
  };

  List<String> get channelLabels => switch (_lastConnectedDevice?.kind) {
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
    DeviceKind.orbit => const ['Fp1', 'Fp2', 'PPG'],
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

  Future<void> requestPermissions() async {
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
        final device = EegDevice(
          name: name.isEmpty ? 'Unknown BLE device' : name,
          id: result.device.remoteId.toString(),
          kind: _kindForName(name),
          isBle: true,
        );
        _addDevice(device);
        final upperName = name.toUpperCase();
        if (autoConnect &&
            (_matchesXampPrefix(name, device.id) ||
                upperName.contains('EPIDOME') ||
                upperName.contains('ORBIT'))) {
          debugPrint(
            '[AcquisitionService] Found BLE target device $name (${device.id}). Auto-connecting!',
          );
          unawaited(connect(device));
          return;
        }
      }
    });

    await _classicScanSub?.cancel();
    _classicScanSub = classic.FlutterBluetoothSerial.instance
        .startDiscovery()
        .listen((result) {
          final name = result.device.name ?? 'Unknown classic device';
          if (_kindForName(name) != DeviceKind.epidome) return;
          final device = EegDevice(
            name: name,
            id: result.device.address,
            kind: _kindForName(name),
            isBle: false,
          );
          _addDevice(device);
        });

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

  Future<void> connect(EegDevice device) async {
    if ((_currentState == AcquisitionState.streaming ||
            _currentState == AcquisitionState.connecting) &&
        _lastConnectedDevice == device) {
      debugPrint(
        '[AcquisitionService] Already connected/connecting to ${device.name}! Skipping redundant connect call.',
      );
      return;
    }
    await stopScan();
    await _cleanupSockets();

    final isEeg =
        device.kind == DeviceKind.epidome || device.kind == DeviceKind.orbit;
    final targetDevice = isEeg
        ? EegDevice(
            name: device.name,
            id: device.id,
            kind: device.kind,
            isBle: true,
          )
        : device;

    if (Platform.isAndroid && targetDevice.isBle) {
      await Future.delayed(const Duration(milliseconds: 500));
    }
    _setState(AcquisitionState.connecting);

    try {
      _lastConnectedDevice = targetDevice;
      _autoReconnectEnabled = true;
      _reconnectAttempts = 0;
      if (targetDevice.kind == DeviceKind.synthetic) {
        _startSynthetic();
      } else if (targetDevice.isBle) {
        await _connectBle(targetDevice);
      } else {
        await _connectClassic(targetDevice);
      }
      _startWatchdog();
      _alertService?.stopBeeping();
    } catch (e) {
      debugPrint(
        '[AcquisitionService] Connect error: $e. Initiating auto-reconnect & warning beep...',
      );
      _handleUnexpectedDisconnect();
    }
  }

  void _startWatchdog() {
    _stopWatchdog();
    _lastSampleTime = DateTime.now().add(Duration(seconds: disconnectionTimeoutSeconds));
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
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopWatchdog();
    _alertService?.stopBeeping();
    await _cleanupSockets();
  }

  Future<void> _cleanupSockets() async {
    _syntheticTimer?.cancel();
    _syntheticTimer = null;
    await _classicInputSub?.cancel();
    await _classicConnection?.close();
    _classicConnection = null;
    await _bleNotifySub?.cancel();
    await _bleConnectionStateSub?.cancel();
    _bleConnectionStateSub = null;
    try {
      await _bleDevice?.disconnect();
    } catch (_) {}
    _bleDevice = null;
    _classicBuffer.clear();
    _bleBuffer.clear();
    _orbitTextBuffer = '';
    if (_currentState != AcquisitionState.disconnected &&
        _currentState != AcquisitionState.connecting) {
      _setState(AcquisitionState.disconnected);
    }
  }

  @override
  void dispose() {
    unawaited(disconnect());
    _state.close();
    _samples.close();
    _devices.close();
    _maxRetriesReachedController.close();
    super.dispose();
  }

  void _handleUnexpectedDisconnect() {
    if (!_autoReconnectEnabled || _lastConnectedDevice == null) {
      return;
    }
    if (_reconnectTimer != null && _reconnectTimer!.isActive) {
      debugPrint(
        '[AcquisitionService] Reconnect timer already active, ignoring unexpected disconnect event.',
      );
      return;
    }
    debugPrint(
      '[AcquisitionService] Unexpected disconnect / watchdog timeout detected!',
    );
    _stopWatchdog();
    _setState(AcquisitionState.disconnected);
    if (reconnectBeepEnabled) {
      _alertService?.startBeeping();
    }
    _cleanupStaleConnection().then((_) {
      _startReconnectTimer();
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
    try {
      _classicConnection?.dispose();
    } catch (_) {}
    _classicConnection = null;
    try {
      await _bleDevice?.disconnect();
    } catch (_) {}
    _bleDevice = null;
  }

  void _startReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(Duration(seconds: reconnectIntervalSec), (
      timer,
    ) async {
      _reconnectAttempts++;
      if (reconnectMaxAttempts > 0 &&
          _reconnectAttempts > reconnectMaxAttempts) {
        _stopReconnectTimer();
        // Keep beeping to alert the user until a successful reconnection happens or they exit!
        _maxRetriesReachedController.add(null);
        return;
      }
      if (_lastConnectedDevice == null || !_autoReconnectEnabled) {
        _stopReconnectTimer();
        _alertService?.stopBeeping();
        return;
      }

      debugPrint(
        '[AcquisitionService] Auto-reconnect attempt $_reconnectAttempts'
        '${reconnectMaxAttempts > 0 ? '/$reconnectMaxAttempts' : ''}: '
        'connecting to ${_lastConnectedDevice!.name}',
      );

      try {
        await connect(_lastConnectedDevice!);
        debugPrint('[AcquisitionService] Auto-reconnect successful!');
        _alertService?.stopBeeping();
      } catch (e) {
        debugPrint('[AcquisitionService] Auto-reconnect failed: $e');
        _setState(AcquisitionState.disconnected);
        if (reconnectBeepEnabled) {
          _alertService?.startBeeping();
        }
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
        if (device.kind == DeviceKind.epidome) {
          _parseEpiDomeBytes(Uint8List.fromList(data));
        } else {
          _parseAsciiOrbit(Uint8List.fromList(data));
        }
      },
      onDone: () => _handleUnexpectedDisconnect(),
      onError: (e) => _handleUnexpectedDisconnect(),
    );
    _setState(AcquisitionState.streaming);
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
    final pair = device.kind == DeviceKind.epidome
        ? _selectEpiDomeCharacteristics(characteristics)
        : _selectOrbitCharacteristics(characteristics);
    final notify = pair?.notify;
    final write = pair?.write;
    if (notify == null) {
      throw StateError('No BLE notify characteristic found for ${device.name}');
    }
    await notify.setNotifyValue(true);
    if (write != null) {
      final command = device.kind == DeviceKind.epidome
          ? [0x72, 0x78, 0x73, 0x37]
          : utf8.encode('9');
      final withoutResponse =
          write.properties.writeWithoutResponse && !write.properties.write;
      await write.write(command, withoutResponse: withoutResponse);
    }
    _bleNotifySub = notify.onValueReceived.listen((data) {
      if (device.kind == DeviceKind.epidome) {
        _parseEpiDomeBytes(Uint8List.fromList(data), bleSource: true);
      } else {
        _parseOrbitBleBytes(data);
      }
    });
    _setState(AcquisitionState.streaming);
    _alertService?.stopBeeping();
  }

  void _parseEpiDomeBytes(Uint8List data, {bool bleSource = false}) {
    _lastSampleTime = DateTime.now();
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
        var raw =
            (buffer[offset] << 16) |
            (buffer[offset + 1] << 8) |
            buffer[offset + 2];
        if ((raw & 0x800000) != 0) raw -= 0x1000000;
        channels[i] = raw * _ads1299UvPerCount;
      }
      buffer.removeRange(0, _epidomeFrameLength);
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

  void _parseAsciiOrbit(Uint8List data, {bool bleSource = false}) {
    _lastSampleTime = DateTime.now();
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
        while (chs.length < 3) chs.add(0.0);

        final rawPpg = chs[2];
        final ppgY = rawPpg - _ppgX1 + 0.995 * _ppgY1;
        _ppgX1 = rawPpg;
        _ppgY1 = ppgY;
        _ppgSmooth = 0.12 * ppgY + 0.88 * _ppgSmooth;
        chs[2] = _ppgSmooth * 0.15;

        _samples.add(
          EegSample(
            channels: chs,
            sampleRate: 250,
            timestamp: DateTime.now(),
            source: 'Orbit',
          ),
        );
      }
    }
  }

  void _parseOrbitBleBytes(List<int> data) {
    _lastSampleTime = DateTime.now();
    _orbitTextBuffer += utf8.decode(data, allowMalformed: true);
    while (true) {
      final start = _orbitTextBuffer.indexOf('{');
      if (start < 0) {
        if (_orbitTextBuffer.length > 500) _orbitTextBuffer = '';
        return;
      }
      final end = _orbitTextBuffer.indexOf('}', start);
      if (end < 0) return;
      final packet = _orbitTextBuffer.substring(start, end + 1);
      _orbitTextBuffer = _orbitTextBuffer.substring(end + 1);
      try {
        final normalized = packet.replaceAllMapped(
          RegExp(r'([\{,]\s*)([A-Za-z]+)(\s*:)'),
          (match) => '${match.group(1)}"${match.group(2)}"${match.group(3)}',
        );
        final json = jsonDecode(normalized) as Map<String, dynamic>;
        final a = _numberList(json['A']);
        final b = _numberList(json['B']);
        final e = _numberList(json['E']);
        final count = min(a.length, b.length);
        for (var i = 0; i < count; i++) {
          final chs = [-0.0224 * a[i], -0.0224 * b[i]];
          if (e.isNotEmpty) {
            final rawPpg = i < e.length ? e[i].toDouble() : e[0].toDouble();
            final ppgY = rawPpg - _ppgX1 + 0.995 * _ppgY1;
            _ppgX1 = rawPpg;
            _ppgY1 = ppgY;
            _ppgSmooth = 0.12 * ppgY + 0.88 * _ppgSmooth;
            chs.add(_ppgSmooth * 0.15);
          }
          while (chs.length < 3) chs.add(0.0);
          _samples.add(
            EegSample(
              channels: chs,
              sampleRate: 250,
              timestamp: DateTime.now(),
              source: 'Orbit',
            ),
          );
        }
      } catch (error) {
        debugPrint('[Orbit parse] $error');
      }
    }
  }

  List<double> _numberList(Object? value) {
    if (value is List) {
      return value.whereType<num>().map((entry) => entry.toDouble()).toList();
    }
    if (value is num) return [value.toDouble()];
    return const [];
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

  void _startSynthetic() {
    _setState(AcquisitionState.streaming);
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

  DeviceKind _kindForName(String name) {
    final upper = name.toUpperCase();
    if (orbitPrefix.isNotEmpty && upper.startsWith(orbitPrefix.toUpperCase())) {
      return DeviceKind.orbit;
    }
    if (_matchesXampPrefix(name) ||
        upper.contains('AXXSPU') ||
        upper.contains('EPIDOME') ||
        upper.contains('XAMP')) {
      return DeviceKind.epidome;
    }
    if (upper.contains('ORBIT')) return DeviceKind.orbit;
    return DeviceKind.epidome;
  }

  bool _matchesXampPrefix(String name, [String? id]) {
    final prefix = xampPrefix.trim().toUpperCase();
    if (prefix.isEmpty) return false;
    final nameMatches =
        name.toUpperCase().startsWith(prefix) ||
        name.toUpperCase().contains(prefix);
    final idMatches = id != null && id.toUpperCase().contains(prefix);
    return nameMatches || idMatches;
  }

  void _addDevice(EegDevice device) {
    if (device.kind != DeviceKind.synthetic &&
        !_matchesXampPrefix(device.name, device.id) &&
        !device.name.toUpperCase().contains('AXXSPU') &&
        !device.name.toUpperCase().contains('EPIDOME') &&
        !device.name.toUpperCase().contains('ORBIT')) {
      return;
    }
    final isEeg =
        device.kind == DeviceKind.epidome || device.kind == DeviceKind.orbit;
    final normalized = isEeg
        ? EegDevice(
            name: device.name,
            id: device.id,
            kind: device.kind,
            isBle: true,
          )
        : device;

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
