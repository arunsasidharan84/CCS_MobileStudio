import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:liblsl/lsl.dart';

import '../models/eeg_sample.dart';
import '../models/lsl_config.dart';
import 'acquisition_service.dart' show AcquisitionState;

/// Acquisition service for EEG data received via LSL (Lab Streaming Layer).
class LslEegAcquisitionService extends ChangeNotifier {
  final _state = StreamController<AcquisitionState>.broadcast();
  final _samples = StreamController<EegSample>.broadcast();

  AcquisitionState _currentState = AcquisitionState.disconnected;
  LSLInlet<double>? _inlet;
  bool _running = false;
  List<String> _channelNames = [];
  double _nominalSampleRate = 250.0;
  int _channelCount = 0;

  // Reconnect support
  LslConfig? _lastConfig;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  /// Maximum number of auto-reconnect attempts before giving up.
  /// Set to 0 for unlimited retries.
  int reconnectMaxAttempts = 10;

  final _maxRetriesReachedController = StreamController<void>.broadcast();

  /// Fires once when auto-reconnect has exhausted [reconnectMaxAttempts].
  Stream<void> get maxRetriesReached => _maxRetriesReachedController.stream;

  static const _networkChannel = MethodChannel('trainNidra/network');

  Stream<AcquisitionState> get state => _state.stream;
  Stream<EegSample> get samples => _samples.stream;
  AcquisitionState get currentState => _currentState;
  List<String> get channelNames => List.unmodifiable(_channelNames);
  int get channelCount => _channelCount;
  double get sampleRate => _nominalSampleRate;

  void _setState(AcquisitionState s) {
    _currentState = s;
    if (!_state.isClosed) {
      _state.add(s);
    }
    notifyListeners();
  }

  /// Resolve and connect to an EEG LSL stream matching the given config.
  Future<bool> connect(LslConfig config) async {
    await disconnect();
    _lastConfig = config;
    _setState(AcquisitionState.connecting);

    try {
      await _acquireMulticastLock();

      final streams = await _resolveStreams(config);
      if (streams.isEmpty) {
        debugPrint('[LSL-EEG] No matching EEG streams found.');
        _setState(AcquisitionState.disconnected);
        await _releaseMulticastLock();
        return false;
      }

      final selected = _selectStream(streams, config.eegStreamName);
      _channelCount = selected.channelCount;
      _nominalSampleRate = selected.sampleRate;
      _channelNames = List.generate(_channelCount, (i) => 'EEG ${i + 1}');

      debugPrint(
        '[LSL-EEG] Connecting to: ${selected.streamName} '
        '(${_channelCount}ch @ ${_nominalSampleRate}Hz)',
      );

      final inlet = LSLInlet<double>(
        selected,
        maxBuffer: 30,
        chunkSize: 0,
        recover: true,
      );
      await inlet.create();
      _inlet = inlet;
      _running = true;
      _reconnectAttempts = 0;
      _stopLslReconnectTimer();
      _setState(AcquisitionState.streaming);
      _pullSamples();
      return true;
    } catch (e) {
      debugPrint('[LSL-EEG] Connection failed: $e');
      _setState(AcquisitionState.disconnected);
      await _releaseMulticastLock();
      return false;
    }
  }

  Future<List<LSLStreamInfo>> _resolveStreams(LslConfig config) async {
    final typesToTry = <String>{config.eegStreamType, 'EEG'}.toList();

    if (config.eegStreamName.isNotEmpty) {
      final resolver = LSLStreamResolver(maxStreams: 10)..create();
      try {
        final byName = await resolver.resolveByProperty(
          property: LSLStreamProperty.name,
          value: config.eegStreamName,
          waitTime: config.resolveTimeoutSeconds,
        );
        resolver.destroy();
        final filtered = byName
            .where(
              (s) => typesToTry.any(
                (t) => s.streamType.value.toUpperCase() == t.toUpperCase(),
              ),
            )
            .toList();
        if (filtered.isNotEmpty) return filtered;
      } catch (_) {
        resolver.destroy();
      }
    }

    for (final type in typesToTry) {
      final resolver = LSLStreamResolver(maxStreams: 10)..create();
      try {
        final results = await resolver.resolveByProperty(
          property: LSLStreamProperty.type,
          value: type,
          waitTime: config.resolveTimeoutSeconds,
        );
        resolver.destroy();
        if (results.isNotEmpty) return results;
      } catch (_) {
        resolver.destroy();
      }
    }
    return [];
  }

  LSLStreamInfo _selectStream(
    List<LSLStreamInfo> streams,
    String preferredName,
  ) {
    if (preferredName.isNotEmpty) {
      final target = preferredName.toLowerCase();
      return streams.firstWhere(
        (s) => s.streamName.toLowerCase() == target,
        orElse: () => streams.firstWhere(
          (s) => s.streamName.toLowerCase().contains(target),
          orElse: () => streams.first,
        ),
      );
    }
    return streams.firstWhere(
      (s) => s.streamName.toLowerCase().contains('liveamp'),
      orElse: () => streams.first,
    );
  }

  Future<void> _pullSamples() async {
    final inlet = _inlet;
    while (_running && inlet != null) {
      try {
        final sample = await inlet.pullSample(timeout: 1.0);
        if (sample.data.isNotEmpty) {
          final channels = sample.data.toList();
          _samples.add(
            EegSample(
              channels: channels,
              sampleRate: _nominalSampleRate,
              timestamp: DateTime.now(),
              source: 'LSL-EEG',
            ),
          );
        }
      } catch (e) {
        if (_running) {
          debugPrint(
            '[LSL-EEG] Sample pull error: $e — starting LSL reconnect',
          );
          try {
            _inlet?.destroy();
          } catch (_) {}
          _inlet = null;
          _setState(AcquisitionState.disconnected);
          await _releaseMulticastLock();
          _startLslReconnectTimer();
        }
        break;
      }
    }
  }

  void _startLslReconnectTimer() {
    if (_lastConfig == null) return;
    _stopLslReconnectTimer();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      _reconnectAttempts++;
      if (reconnectMaxAttempts > 0 &&
          _reconnectAttempts > reconnectMaxAttempts) {
        _stopLslReconnectTimer();
        if (!_maxRetriesReachedController.isClosed) {
          _maxRetriesReachedController.add(null);
        }
        return;
      }

      if (_currentState == AcquisitionState.streaming ||
          _currentState == AcquisitionState.connecting) {
        return;
      }

      debugPrint(
        '[LSL-EEG] Auto-reconnect attempt $_reconnectAttempts'
        '${reconnectMaxAttempts > 0 ? '/$reconnectMaxAttempts' : ''}',
      );

      if (_lastConfig != null) {
        await connect(_lastConfig!);
      }
    });
  }

  void _stopLslReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  Future<void> disconnect() async {
    _running = false;
    _reconnectAttempts = 0;
    _stopLslReconnectTimer();
    try {
      _inlet?.destroy();
    } catch (_) {}
    _inlet = null;
    _channelNames = [];
    _channelCount = 0;
    await _releaseMulticastLock();
    _setState(AcquisitionState.disconnected);
  }

  @override
  void dispose() {
    disconnect();
    _state.close();
    _samples.close();
    _maxRetriesReachedController.close();
    super.dispose();
  }

  Future<void> _acquireMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('acquireMulticastLock');
    } catch (e) {
      debugPrint('[LSL-EEG] Multicast lock acquire failed: $e');
    }
  }

  Future<void> _releaseMulticastLock() async {
    if (!Platform.isAndroid) return;
    try {
      await _networkChannel.invokeMethod('releaseMulticastLock');
    } catch (e) {
      debugPrint('[LSL-EEG] Multicast lock release failed: $e');
    }
  }
}
