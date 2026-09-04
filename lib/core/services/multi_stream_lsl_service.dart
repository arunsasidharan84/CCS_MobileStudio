import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:liblsl/lsl.dart';

import '../eeg/acquisition_service.dart' show AcquisitionState;
import '../models/device_profile.dart';
import '../models/signal_stream_sample.dart';
import '../models/stream_marker.dart';

/// Connects every enabled stream in every enabled LSL device profile.
class MultiStreamLslService extends ChangeNotifier {
  static const _networkChannel = MethodChannel('trainNidra/network');
  final _samples = StreamController<SignalStreamSample>.broadcast();
  final _markers = StreamController<StreamMarker>.broadcast();
  final Map<String, LSLInlet<double>> _inlets = {};
  final Map<String, LSLInlet<String>> _markerInlets = {};
  final Map<String, SignalStreamProfile> _profiles = {};
  final Set<String> _running = {};
  AcquisitionState _state = AcquisitionState.disconnected;

  Stream<SignalStreamSample> get samples => _samples.stream;
  Stream<StreamMarker> get markers => _markers.stream;
  AcquisitionState get state => _state;
  bool get isConnected => _inlets.isNotEmpty || _markerInlets.isNotEmpty;
  List<StreamMarker> recentMarkers = [];
  List<SignalStreamProfile> get connectedStreams =>
      List.unmodifiable(_profiles.values);
  Map<String, SignalStreamProfile> get connectedStreamProfiles =>
      Map.unmodifiable(_profiles);

  Future<int> connectConfigured(Iterable<DeviceProfile> devices) async {
    await disconnect();
    final targets = devices
        .where(
          (device) =>
              device.enabled && device.transport == ConnectionTransport.lsl,
        )
        .expand(
          (device) => device.enabledStreams.map(
            (stream) => (device: device, stream: stream),
          ),
        )
        .toList();
    if (targets.isEmpty) return 0;
    _setState(AcquisitionState.connecting);
    await _acquireMulticastLock();
    for (final target in targets) {
      await _connectStream(target.device, target.stream);
    }
    _setState(
      _inlets.isEmpty && _markerInlets.isEmpty
          ? AcquisitionState.disconnected
          : AcquisitionState.streaming,
    );
    if (_inlets.isEmpty && _markerInlets.isEmpty) {
      await _releaseMulticastLock();
    }
    return _inlets.length + _markerInlets.length;
  }

  Future<void> _connectStream(
    DeviceProfile device,
    SignalStreamProfile configured,
  ) async {
    final resolver = LSLStreamResolver(maxStreams: 20)..create();
    try {
      List<LSLStreamInfo> matches = [];
      if (configured.lslName.trim().isNotEmpty) {
        matches = await resolver.resolveByProperty(
          property: LSLStreamProperty.name,
          value: configured.lslName.trim(),
          waitTime: 3,
        );
      }
      if (matches.isEmpty) {
        final type = configured.lslType.trim().isEmpty
            ? configured.signalType.label
            : configured.lslType.trim();
        matches = await resolver.resolveByProperty(
          property: LSLStreamProperty.type,
          value: type,
          waitTime: 3,
        );
      }
      if (matches.isEmpty) return;
      final info = matches.first;
      final key = '${device.id}:${configured.id}';
      if (configured.signalType == SignalType.marker) {
        final inlet = LSLInlet<String>(
          info,
          maxBuffer: 600,
          chunkSize: 0,
          recover: true,
        );
        await inlet.create();
        final runtime = SignalStreamProfile.fromJson(configured.toJson())
          ..sampleRate = 0;
        _markerInlets[key] = inlet;
        _profiles[key] = runtime;
        _running.add(key);
        unawaited(_pullMarkers(key, device.name, inlet));
        return;
      }
      final inlet = LSLInlet<double>(
        info,
        maxBuffer: 60,
        chunkSize: 0,
        recover: true,
      );
      await inlet.create();
      final labels = configured.channelLabels.length == info.channelCount
          ? configured.channelLabels
          : List.generate(
              info.channelCount,
              (index) => '${configured.signalType.label} ${index + 1}',
            );
      final runtime = SignalStreamProfile.fromJson(configured.toJson())
        ..channelLabels = List<String>.of(labels)
        ..channelTypes = SignalStreamProfile.normalizeChannelTypes(
          labels,
          configured.channelTypes,
        )
        ..sampleRate = info.sampleRate > 0
            ? info.sampleRate
            : configured.sampleRate;
      _inlets[key] = inlet;
      _profiles[key] = runtime;
      _running.add(key);
      unawaited(_pull(key, device.id, inlet, runtime));
      debugPrint(
        '[Multi LSL] ${info.streamName}: ${info.channelCount} ch @ ${runtime.sampleRate} Hz',
      );
    } catch (error) {
      debugPrint('[Multi LSL] ${configured.name} failed: $error');
    } finally {
      resolver.destroy();
    }
  }

  Future<void> _pullMarkers(
    String key,
    String source,
    LSLInlet<String> inlet,
  ) async {
    while (_running.contains(key)) {
      try {
        final sample = await inlet.pullSample(timeout: 1);
        if (sample.data.isEmpty) continue;
        for (final value in sample.data) {
          final marker = StreamMarker(
            streamId: key,
            source: source,
            value: value,
            code: StreamMarker.codeForValue(value),
            receivedAt: DateTime.now(),
            lslTimestamp: sample.timestamp,
          );
          recentMarkers = [...recentMarkers, marker];
          if (recentMarkers.length > 100) {
            recentMarkers = recentMarkers.sublist(recentMarkers.length - 100);
          }
          _markers.add(marker);
          notifyListeners();
        }
      } catch (error) {
        if (_running.contains(key)) {
          debugPrint('[Multi LSL] marker pull failed: $error');
        }
        break;
      }
    }
  }

  Future<void> _pull(
    String key,
    String deviceId,
    LSLInlet<double> inlet,
    SignalStreamProfile profile,
  ) async {
    while (_running.contains(key)) {
      try {
        final sample = await inlet.pullSample(timeout: 1);
        if (sample.data.isEmpty) continue;
        _samples.add(
          SignalStreamSample(
            deviceProfileId: deviceId,
            streamId: key,
            signalType: profile.signalType,
            channels: sample.data.toList(),
            channelLabels: profile.channelLabels,
            channelTypes: profile.channelTypes,
            sampleRate: profile.sampleRate,
            timestamp: DateTime.now(),
            unit: profile.unit,
            physicalMinimum: profile.physicalMinimum,
            physicalMaximum: profile.physicalMaximum,
          ),
        );
      } catch (error) {
        if (_running.contains(key)) {
          debugPrint('[Multi LSL] ${profile.name} pull failed: $error');
        }
        break;
      }
    }
  }

  Future<void> disconnect() async {
    _running.clear();
    for (final inlet in _inlets.values) {
      try {
        inlet.destroy();
      } catch (_) {}
    }
    for (final inlet in _markerInlets.values) {
      try {
        inlet.destroy();
      } catch (_) {}
    }
    _inlets.clear();
    _markerInlets.clear();
    _profiles.clear();
    recentMarkers = [];
    await _releaseMulticastLock();
    _setState(AcquisitionState.disconnected);
  }

  void _setState(AcquisitionState value) {
    _state = value;
    notifyListeners();
  }

  Future<void> _acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('acquireMulticastLock');
    } catch (_) {}
  }

  Future<void> _releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('releaseMulticastLock');
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(disconnect());
    _samples.close();
    _markers.close();
    super.dispose();
  }
}
